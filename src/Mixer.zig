const std = @import("std");
const assert = std.debug.assert;
const SampleReader = @import("wav.zig").SampleReader;

sources: []const SampleReader,
volumes: []const f32,
clip: bool,

const Self = @This();

pub fn init(sources: []const SampleReader, volumes: []const f32, clip: bool) Self {
    assert(sources.len > 0);
    assert(sources.len == volumes.len);
    for (sources) |source| {
        assert(source.channels == sources[0].channels);
        assert(source.sample_rate == sources[0].sample_rate);
    }

    return .{
        .sources = sources,
        .volumes = volumes,
        .clip = clip,
    };
}

pub fn mix(self: Self, buf: []f32) !usize {
    for (buf, 0..) |*b, i| {
        b.* = 0.0;
        var end = true;
        for (self.sources, self.volumes) |src, volume| {
            if (try src.readOrNull()) |sample| {
                end = false;
                b.* += sample * volume;
            }
        }
        if (end) {
            return i;
        }

        if (self.clip) {
            b.* = std.math.clamp(b.*, -1.0, 1.0);
        }
    }
    return buf.len;
}

fn typeErasedMix(context: *anyopaque, buf: []f32) anyerror!usize {
    const self: *Self = @alignCast(@ptrCast(context));
    return mix(self.*, buf);
}

pub fn reader(self: *Self) SampleReader {
    return .{
        .channels = self.sources[0].channels,
        .sample_rate = self.sources[0].sample_rate,
        .context = @ptrCast(self),
        .readFn = typeErasedMix,
    };
}
