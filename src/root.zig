const std = @import("std");
const AnyReader = std.io.AnyReader;
const expectEqual = std.testing.expectEqual;
const expectError = std.testing.expectError;

const builtin = @import("builtin");

pub const Mixer = @import("Mixer.zig");
pub const Resampler = @import("Resampler.zig");
pub const sample = @import("sample.zig");
pub const SampleReader = @import("SampleReader.zig");

const bad_type = "sample type must be u8, i16, i24, or f32";

fn readFloat(comptime T: type, reader: AnyReader) !T {
    var f: T = undefined;
    try reader.readNoEof(std.mem.asBytes(&f));
    return f;
}

pub const FormatCode = enum(u16) {
    pcm = 1,
    ieee_float = 3,
    alaw = 6,
    mulaw = 7,
    extensible = 0xFFFE,
    _,
};

pub const FormatChunk = packed struct {
    code: FormatCode,
    channels: u16,
    sample_rate: u32,
    bytes_per_second: u32,
    block_align: u16,
    bits: u16,

    pub fn parse(reader: AnyReader, chunk_size: usize) !FormatChunk {
        if (chunk_size < @sizeOf(FormatChunk)) {
            return error.InvalidSize;
        }
        const fmt = try reader.readStruct(FormatChunk);
        if (chunk_size > @sizeOf(FormatChunk)) {
            try reader.skipBytes(chunk_size - @sizeOf(FormatChunk), .{});
        }
        return fmt;
    }

    pub fn validate(self: FormatChunk) !void {
        switch (self.code) {
            .pcm, .ieee_float, .extensible => {},
            else => {
                std.log.debug("unsupported format code {x}", .{@intFromEnum(self.code)});
                return error.Unsupported;
            },
        }
        if (self.channels == 0) {
            return error.InvalidValue;
        }
        switch (self.bits) {
            0 => return error.InvalidValue,
            8, 16, 24, 32 => {},
            else => {
                std.log.debug("unsupported bits per sample {}", .{self.bits});
                return error.Unsupported;
            },
        }
        if (self.bytes_per_second != self.bits / 8 * self.sample_rate * self.channels) {
            std.log.debug("invalid bytes_per_second", .{});
            return error.InvalidValue;
        }
    }
};

/// Loads wav file from stream. Read and convert samples to a desired type.
pub const Decoder = struct {
    const Self = @This();

    const ReaderType = std.io.CountingReader(AnyReader);
    pub const Error = ReaderType.Error || error{ EndOfStream, InvalidFileType, InvalidArgument, InvalidSize, InvalidValue, Overflow, Unsupported };

    counting_reader: ReaderType,
    fmt: FormatChunk,
    data_start: usize,
    data_size: usize,

    pub fn sampleRate(self: *const Self) u32 {
        return self.fmt.sample_rate;
    }

    pub fn channels(self: *const Self) u16 {
        return self.fmt.channels;
    }

    pub fn bits(self: *const Self) u16 {
        return self.fmt.bits;
    }

    /// Number of samples remaining.
    pub fn remaining(self: *const Self) usize {
        const sample_size = self.bits() / 8;
        const bytes_remaining = self.data_size + self.data_start - self.counting_reader.bytes_read;

        std.debug.assert(bytes_remaining % sample_size == 0);
        return bytes_remaining / sample_size;
    }

    /// Parse and validate headers/metadata. Prepare to read samples.
    pub fn init(inner_reader: AnyReader) Error!Self {
        comptime std.debug.assert(builtin.target.cpu.arch.endian() == .little);

        var cr = ReaderType{ .child_reader = inner_reader };
        var counting_reader = cr.reader();

        var chunk_id = try counting_reader.readBytesNoEof(4);
        if (!std.mem.eql(u8, "RIFF", &chunk_id)) {
            std.log.debug("not a RIFF file", .{});
            return error.InvalidFileType;
        }
        const total_size = try std.math.add(u32, try counting_reader.readInt(u32, .little), 8);

        chunk_id = try counting_reader.readBytesNoEof(4);
        if (!std.mem.eql(u8, "WAVE", &chunk_id)) {
            std.log.debug("not a WAVE file", .{});
            return error.InvalidFileType;
        }

        // Iterate through chunks. Require fmt and data.
        var fmt: ?FormatChunk = null;
        var data_size: usize = 0; // Bytes in data chunk.
        var chunk_size: usize = 0;
        while (true) {
            chunk_id = try counting_reader.readBytesNoEof(4);
            chunk_size = try counting_reader.readInt(u32, .little);

            if (std.mem.eql(u8, "fmt ", &chunk_id)) {
                fmt = try FormatChunk.parse(counting_reader.any(), chunk_size);
                try fmt.?.validate();

                // TODO Support 32-bit aligned i24 blocks.
                const bytes_per_sample = fmt.?.block_align / fmt.?.channels;
                if (bytes_per_sample * 8 != fmt.?.bits) {
                    return error.Unsupported;
                }
            } else if (std.mem.eql(u8, "data", &chunk_id)) {
                // Expect data chunk to be last.
                data_size = chunk_size;
                break;
            } else {
                std.log.info("skipping unrecognized chunk {s}", .{chunk_id});
                try counting_reader.skipBytes(chunk_size, .{});
            }
        }

        if (fmt == null) {
            std.log.debug("no fmt chunk present", .{});
            return error.InvalidFileType;
        }

        std.log.info(
            "{}(bits={}) sample_rate={} channels={} size=0x{x}",
            .{ fmt.?.code, fmt.?.bits, fmt.?.sample_rate, fmt.?.channels, total_size },
        );

        const data_start = cr.bytes_read;
        if (data_start + data_size > total_size) {
            return error.InvalidSize;
        }
        if (data_size % (fmt.?.channels * fmt.?.bits / 8) != 0) {
            return error.InvalidSize;
        }

        return .{
            .counting_reader = cr,
            .fmt = fmt.?,
            .data_start = data_start,
            .data_size = data_size,
        };
    }

    pub fn readInternal(self: *Self, comptime Src: type, comptime Dst: type, buf: []Dst) Error!usize {
        var any_reader = self.counting_reader.reader().any();

        const limit = @min(buf.len, self.remaining());
        var i: usize = 0;
        while (i < limit) : (i += 1) {
            buf[i] = sample.convert(
                Dst,
                // Propagate EndOfStream error on truncation.
                switch (@typeInfo(Src)) {
                    .float => try readFloat(Src, any_reader),
                    .int => try any_reader.readInt(Src, .little),
                    else => @compileError(bad_type),
                },
            );
        }
        return i;
    }

    /// Read samples from stream and converts to type T. Supports PCM encoded ints and IEEE float.
    /// Multi-channel samples are interleaved: samples for time `t` for all channels are written to
    /// `t * channels`. Thus, `buf.len` must be evenly divisible by `channels`.
    ///
    /// Returns: number of bytes read. 0 indicates end of stream.
    pub fn read(self: *Self, comptime T: type, buf: []T) Error!usize {
        return switch (self.fmt.code) {
            .pcm => switch (self.fmt.bits) {
                8 => self.readInternal(u8, T, buf),
                16 => self.readInternal(i16, T, buf),
                24 => self.readInternal(i24, T, buf),
                32 => self.readInternal(i32, T, buf),
                else => std.debug.panic("invalid decoder state, unexpected fmt bits {}", .{self.fmt.bits}),
            },
            .ieee_float => self.readInternal(f32, T, buf),
            else => std.debug.panic("invalid decoder state, unexpected fmt code {}", .{@intFromEnum(self.fmt.code)}),
        };
    }

    /// Read samples from stream and converts to f32. Supports PCM encoded ints and IEEE float.
    /// Multi-channel samples are averaged into a single mono channel sample.
    ///
    /// Returns: number of bytes read. 0 indicates end of stream.
    pub fn readMono(self: *Self, buf: []f32) Error!usize {
        const limit = @min(buf.len, self.remaining() / self.channels());
        for (0..limit) |i| {
            var sum: f32 = 0.0;
            var single_buf: [1]f32 = undefined;
            for (0..self.channels()) |_| {
                std.debug.assert(try self.read(f32, &single_buf) == single_buf.len);
                sum += single_buf[0];
            }
            buf[i] = sum / @as(f32, @floatFromInt(self.channels()));
        }
        return limit;
    }

    fn typeErasedRead(context: *anyopaque, buf: []f32) Error!usize {
        const self: *Self = @alignCast(@ptrCast(context));
        return read(self, f32, buf);
    }

    pub fn reader(self: *Self) SampleReader {
        return .{
            .channels = self.channels(),
            .sample_rate = self.sampleRate(),
            .context = @ptrCast(self),
            .readFn = typeErasedRead,
        };
    }

    fn typeErasedReadMono(context: *anyopaque, buf: []f32) Error!usize {
        const self: *Self = @alignCast(@ptrCast(context));
        return readMono(self, buf);
    }

    pub fn readerMono(self: *Self) SampleReader {
        return .{
            .channels = self.channels(),
            .sample_rate = self.sampleRate(),
            .context = @ptrCast(self),
            .readFn = typeErasedReadMono,
        };
    }
};

test {
    @import("std").testing.refAllDecls(@This());
}
