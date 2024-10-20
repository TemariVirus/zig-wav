//! Resamples audio data to a target sample rate. Output is monophonic.

const std = @import("std");
const AnyWriter = std.io.AnyWriter;
const assert = std.debug.assert;

const wav = @import("wav.zig");
const Decoder = wav.Decoder;

fn readOne(decoder: *Decoder) !?f32 {
    var buf: [32]f32 = undefined;
    const channels = decoder.channels();
    assert(channels <= buf.len);

    const len = try decoder.read(f32, buf[0..channels]);
    if (len == 0) {
        return null;
    }
    assert(len == channels);

    // Combine into 1 channel by averaging
    var mean: f32 = 0.0;
    for (buf[0..channels]) |sample| {
        mean += sample;
    }
    return mean / @as(f32, @floatFromInt(channels));
}

// Windowed sinc resampling
// pub fn resample(decoder: *Decoder, target_sample_rate: u32, comptime window_size: u16, writer: anytype) !void {
//     // Compute the number of output samples
//     const factor_inv = @as(f32, @floatFromInt(decoder.sampleRate())) / @as(f32, @floatFromInt(target_sample_rate));
//     const input_length: usize = decoder.remaining() / decoder.channels();
//     const output_length: usize = @intFromFloat(@as(f32, @floatFromInt(input_length)) / factor_inv);

//     // Precompute the sinc kernel
//     const kernel_size = 2 * window_size + 1;
//     var kernel: [kernel_size]f32 = undefined;
//     var kernel_sum: f32 = 0.0;
//     for (0..kernel_size) |i| {
//         const x1 = @as(f32, @floatFromInt(i)) - @as(f32, window_size);
//         const x2 = x1 * factor_inv;
//         kernel[i] = if (x2 == 0) 1.0 else @sin(x2) / x2;
//         kernel[i] *= 0.5 * (1.0 - @cos(2 * std.math.pi * (0.5 + x1 / @as(f32, @floatFromInt(kernel_size)))));
//         kernel_sum += kernel[i];
//     }
//     // Normalize the kernel
//     for (0..kernel_size) |i| {
//         kernel[i] /= kernel_sum;
//     }

//     // Perform the resampling
//     var input: [kernel_size]f32 = undefined;
//     var input_start: usize = 0;
//     for (0..kernel_size) |i| {
//         input[i] = try readOne(decoder) orelse 0.0;
//     }

//     for (0..output_length) |i| {
//         const input_index = @as(f32, @floatFromInt(i)) * factor_inv;
//         const left_index: isize = @intFromFloat(input_index - @as(f32, window_size));
//         const right_index: isize = @intFromFloat(input_index + @as(f32, window_size) + 1);

//         // Shift the input buffer
//         if (left_index > input_start) {
//             std.mem.copyForwards(
//                 f32,
//                 &input,
//                 input[@as(usize, @intCast(left_index)) - input_start ..],
//             );
//             for (input.len + input_start - @as(usize, @intCast(left_index))..input.len) |j| {
//                 input[j] = try readOne(decoder) orelse 0.0;
//             }
//             input_start = @intCast(left_index);
//         }

//         // Handle edge cases
//         const kernel_start: usize = @max(0, -left_index);
//         const left: usize = @max(0, left_index);
//         const right: usize = @min(input_length, @as(usize, @intCast(right_index - 1)));

//         // Apply the kernel
//         var y: f32 = 0.0;
//         for (0..right - left) |k| {
//             y += input[left - input_start + k] * kernel[kernel_start + k];
//         }
//         try writer.write(f32, &.{y});
//     }
// }

pub fn resampleLinear(
    decoder: *Decoder,
    target_sample_rate: u32,
    writer: anytype,
) !void {
    const in_sample_rate: f32 = @floatFromInt(decoder.sampleRate());
    const in_interval: f32 = 1.0 / in_sample_rate;
    const out_interval: f32 = 1.0 / @as(f32, @floatFromInt(target_sample_rate));

    var read: u32 = 0;
    var in_time: f32 = @as(f32, @floatFromInt(read)) * in_interval;
    var wrote: u32 = 0;
    var out_time: f32 = @as(f32, @floatFromInt(wrote)) * out_interval;

    var first: f32 = undefined;
    var second = try readOne(decoder) orelse return;
    while (try readOne(decoder)) |sample| {
        read += 1;
        in_time = @as(f32, @floatFromInt(read)) * in_interval;
        // Ensure out_time is inbetween the 2 samples (in_time - in_interval, in_time)
        if (in_time < out_time) {
            continue;
        }
        first = second;
        second = sample;

        // Linear interpolation
        while (out_time < in_time) {
            const x = (in_time - out_time) * in_sample_rate;
            try writer.write(f32, &.{first * x + second * (1.0 - x)});

            wrote += 1;
            out_time = @as(f32, @floatFromInt(wrote)) * out_interval;
        }
    }
}

pub fn resampleCubic(
    decoder: *Decoder,
    target_sample_rate: u32,
    writer: anytype,
) !void {
    const in_sample_rate: f32 = @floatFromInt(decoder.sampleRate());
    const in_interval: f32 = 1.0 / in_sample_rate;
    const out_interval: f32 = 1.0 / @as(f32, @floatFromInt(target_sample_rate));

    var read: u32 = 0;
    var in_time: f32 = @as(f32, @floatFromInt(read)) * in_interval;
    var wrote: u32 = 0;
    var out_time: f32 = @as(f32, @floatFromInt(wrote)) * out_interval;

    var samples: [4]f32 = undefined;
    for (samples[1..]) |*sample| {
        sample.* = try readOne(decoder) orelse return;
    }
    read = (samples.len - 1) / 2;
    in_time = @as(f32, @floatFromInt(read)) * in_interval;
    while (try readOne(decoder)) |sample| {
        std.mem.copyForwards(f32, &samples, samples[1..]);
        samples[samples.len - 1] = sample;
        read += 1;
        in_time = @as(f32, @floatFromInt(read)) * in_interval;
        // Ensure out_time is around the middle
        if (in_time < out_time) {
            continue;
        }

        // Cubic interpolation
        while (out_time < in_time) {
            const x = ((samples.len + 1) / 2 - (in_time - out_time) * in_sample_rate) / samples.len;
            const x2 = x * x;
            const x3 = x2 * x;
            const a = -0.5 * samples[0] + 1.5 * samples[1] - 1.5 * samples[2] + 0.5 * samples[3];
            const b = samples[0] - 2.5 * samples[1] + 2.0 * samples[2] - 0.5 * samples[3];
            const c = -0.5 * samples[0] + 0.5 * samples[2];
            const d = samples[1];
            const value = a * x3 + b * x2 + c * x + d;
            try writer.write(f32, &.{value});

            wrote += 1;
            out_time = @as(f32, @floatFromInt(wrote)) * out_interval;
        }
    }
}
