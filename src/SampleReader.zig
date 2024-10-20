const std = @import("std");
const assert = std.debug.assert;
const mem = std.mem;

sample_rate: u32,
channels: u16,
context: *anyopaque,
readFn: *const fn (context: *anyopaque, buffer: []f32) anyerror!usize,

const Self = @This();
pub const Error = anyerror;

/// Returns the number of samples read. It may be less than buffer.len.
/// If the number of samples read is 0, it means end of stream.
/// End of stream is not an error condition.
pub fn read(self: Self, buffer: []f32) anyerror!usize {
    return self.readFn(self.context, buffer);
}

/// Returns the number of smaples read. If the number read is smaller than `buffer.len`,
/// it means the stream reached the end. Reaching the end of a stream is not an error
/// condition.
pub fn readAll(self: Self, buffer: []f32) anyerror!usize {
    return readAtLeast(self, buffer, buffer.len);
}

/// Returns the number of samples read, calling the underlying read
/// function the minimal number of times until the buffer has at least
/// `len` samples filled. If the number read is less than `len` it means
/// the stream reached the end. Reaching the end of the stream is not
/// an error condition.
pub fn readAtLeast(self: Self, buffer: []f32, len: usize) anyerror!usize {
    assert(len <= buffer.len);
    var index: usize = 0;
    while (index < len) {
        const amt = try self.read(buffer[index..]);
        if (amt == 0) break;
        index += amt;
    }
    return index;
}

/// If the number read would be smaller than `buf.len`, `error.EndOfStream` is returned instead.
pub fn readNoEof(self: Self, buf: []f32) anyerror!void {
    const amt_read = try self.readAll(buf);
    if (amt_read < buf.len) return error.EndOfStream;
}

/// Appends to the `std.ArrayList` contents by reading from the stream
/// until end of stream is found.
/// If the number of samples appended would exceed `max_append_size`,
/// `error.StreamTooLong` is returned
/// and the `std.ArrayList` has exactly `max_append_size` samples appended.
pub fn readAllArrayList(
    self: Self,
    array_list: *std.ArrayList(f32),
    max_append_size: usize,
) anyerror!void {
    return self.readAllArrayListAligned(null, array_list, max_append_size);
}

pub fn readAllArrayListAligned(
    self: Self,
    comptime alignment: ?u29,
    array_list: *std.ArrayListAligned(f32, alignment),
    max_append_size: usize,
) anyerror!void {
    try array_list.ensureTotalCapacity(@min(max_append_size, 1024));
    const original_len = array_list.items.len;
    var start_index: usize = original_len;
    while (true) {
        array_list.expandToCapacity();
        const dest_slice = array_list.items[start_index..];
        const samples_read = try self.readAll(dest_slice);
        start_index += samples_read;

        if (start_index - original_len > max_append_size) {
            array_list.shrinkAndFree(original_len + max_append_size);
            return error.StreamTooLong;
        }

        if (samples_read != dest_slice.len) {
            array_list.shrinkAndFree(start_index);
            return;
        }

        // This will trigger ArrayList to expand superlinearly at whatever its growth rate is.
        try array_list.ensureTotalCapacity(start_index + 1);
    }
}

/// Optional parameters for `skipSamples`
pub const ReadAllAllocOptions = struct {
    max_size: usize = 512 * 1024 * 1024 / @sizeOf(f32), // 512MB
};

/// Allocates enough memory to hold all the contents of the stream. If the allocated
/// memory would be greater than `max_size`, returns `error.StreamTooLong`.
/// Caller owns returned memory.
/// If this function returns an error, the contents from the stream read so far are lost.
pub fn readAllAlloc(self: Self, allocator: mem.Allocator, options: ReadAllAllocOptions) anyerror![]f32 {
    var array_list = std.ArrayList(f32).init(allocator);
    defer array_list.deinit();
    try self.readAllArrayList(&array_list, options.max_size);
    return try array_list.toOwnedSlice();
}

/// Reads 1 sample from the stream or returns `error.EndOfStream`.
pub fn readSample(self: Self) anyerror!f32 {
    var result: [1]f32 = undefined;
    const amt_read = try self.read(result[0..]);
    if (amt_read < 1) return error.EndOfStream;
    return result[0];
}

/// Optional parameters for `skipSamples`
pub const SkipSamplesOptions = struct {
    buf_size: usize = 256,
};

// `num_samples` is a `u64` to match `off_t`
/// Reads `num_samples` samples from the stream and discards them
pub fn skipSamples(self: Self, num_samples: u64, comptime options: SkipSamplesOptions) anyerror!void {
    var buf: [options.buf_size]f32 = undefined;
    var remaining = num_samples;

    while (remaining > 0) {
        const amt = @min(remaining, options.buf_size);
        try self.readNoEof(buf[0..amt]);
        remaining -= amt;
    }
}

/// Reads the stream until the end, ignoring all the data.
/// Returns the number of samples discarded.
pub fn discard(self: Self) anyerror!u64 {
    var trash: [1024]f32 = undefined;
    var index: u64 = 0;
    while (true) {
        const n = try self.read(&trash);
        if (n == 0) return index;
        index += n;
    }
}
