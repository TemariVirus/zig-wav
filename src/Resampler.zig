//! Linearly resamples audio data to a target sample rate. Assumes monophonic input.

const std = @import("std");
const assert = std.debug.assert;
const SampleReader = @import("wav.zig").SampleReader;

source: SampleReader,
target_sample_rate: u32,
samples: [2]f32,
read: usize = 0,
wrote: usize = 0,

const Self = @This();

pub fn init(sample_reader: SampleReader, target_sample_rate: u32) !Self {
    assert(sample_reader.channels == 1);
    return .{
        .source = sample_reader,
        .target_sample_rate = target_sample_rate,
        .samples = .{ undefined, try sample_reader.readOrNull() orelse undefined },
    };
}

fn next(self: *Self) !bool {
    const sample = try self.source.readOrNull() orelse return false;
    self.read += 1;

    std.mem.copyForwards(f32, self.samples[0..], self.samples[1..]);
    self.samples[self.samples.len - 1] = sample;
    return true;
}

pub fn resample(self: *Self, buf: []f32) !usize {
    const in_sample_rate: f32 = @floatFromInt(self.source.sample_rate);
    const in_interval: f32 = 1.0 / in_sample_rate;
    const out_interval: f32 = 1.0 / @as(f32, @floatFromInt(self.target_sample_rate));

    var in_time: f32 = @as(f32, @floatFromInt(self.read)) * in_interval;
    var out_time: f32 = @as(f32, @floatFromInt(self.wrote)) * out_interval;

    // Linear interpolation
    const old_wrote = self.wrote;
    outer: while (self.wrote - old_wrote < buf.len) {
        while (out_time < in_time) {
            const x = (in_time - out_time) * in_sample_rate;
            const resampled = self.samples[0] * x + self.samples[1] * (1.0 - x);
            buf[self.wrote - old_wrote] = resampled;

            self.wrote += 1;
            out_time = @as(f32, @floatFromInt(self.wrote)) * out_interval;

            if (self.wrote - old_wrote == buf.len) {
                break :outer;
            }
        }

        if (!try self.next()) {
            break;
        }
        in_time = @as(f32, @floatFromInt(self.read)) * in_interval;
    }

    return self.wrote - old_wrote;
}

fn typeErasedResample(context: *anyopaque, buf: []f32) anyerror!usize {
    const self: *Self = @alignCast(@ptrCast(context));
    return resample(self, buf);
}

pub fn reader(self: *Self) SampleReader {
    return .{
        .channels = 1,
        .sample_rate = self.target_sample_rate,
        .context = @ptrCast(self),
        .readFn = typeErasedResample,
    };
}
