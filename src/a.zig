const std = @import("std");
const wav = @import("wav");
const Mixer = wav.Mixer;
const Resampler = wav.Resampler;

const OUT_SAMPLE_RATE = 48_000;

pub fn main() !void {
    const file1 = try std.fs.cwd().openFile("1.wav", .{});
    defer file1.close();
    const file2 = try std.fs.cwd().openFile("2.wav", .{});
    defer file2.close();
    const file3 = try std.fs.cwd().openFile("3.wav", .{});
    defer file3.close();

    var br1 = std.io.bufferedReader(file1.reader());
    var br2 = std.io.bufferedReader(file2.reader());
    var br3 = std.io.bufferedReader(file3.reader());

    var decoder1 = try wav.Decoder.init(br1.reader().any());
    var decoder2 = try wav.Decoder.init(br2.reader().any());
    var decoder3 = try wav.Decoder.init(br3.reader().any());

    const out = try std.fs.cwd().createFile("out.wav", .{});
    defer out.close();

    var bw = std.io.bufferedWriter(out.writer());
    var encoder = try wav.encoder(f32, bw.writer(), out.seekableStream(), OUT_SAMPLE_RATE, 1);

    const start = std.time.nanoTimestamp();

    var mx = Mixer.init(
        &.{ decoder1.reader(), decoder2.reader(), decoder3.reader() },
        &.{ 1.8, 2.25, 1.5 },
    );
    const mixer = mx.reader();

    var rs = try Resampler.init(mixer, OUT_SAMPLE_RATE);
    const resampler = rs.reader();

    while (try resampler.readOrNull()) |sample| {
        try encoder.write(f32, &.{sample});
    }
    try bw.flush();

    try encoder.finalize();
    try bw.flush();

    const end = std.time.nanoTimestamp();
    const elapsed: u64 = @intCast(end - start);
    std.debug.print("Took: {}\n", .{std.fmt.fmtDuration(elapsed)});
}
