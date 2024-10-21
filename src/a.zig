const std = @import("std");
const wav = @import("wav");
const AccumFuncs = wav.SampleReader.AccumFuncs;
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

    const start = std.time.nanoTimestamp();

    var encoder = try wav.encoder(
        u8,
        bw.writer(),
        out.seekableStream(),
        OUT_SAMPLE_RATE,
        1,
    );

    var mx = Mixer.init(
        &.{ decoder1.reader(), decoder2.reader(), decoder3.reader() },
        &.{ 1.8, 2.25, 1.5 },
        false,
    );
    const mixer = mx.reader();

    const max_norm = (try mixer.accumulate(0.0, AccumFuncs.absMax));
    std.debug.print("max norm: {d}\n", .{max_norm});
    mx = Mixer.init(
        &.{ decoder1.reader(), decoder2.reader(), decoder3.reader() },
        &.{ 1.8 / max_norm, 2.25 / max_norm, 1.5 / max_norm },
        true,
    );
    decoder1.counting_reader.bytes_read = decoder1.data_start;
    try file1.seekTo(decoder1.data_start);
    br1.start = 0;
    br1.end = 0;
    decoder2.counting_reader.bytes_read = decoder2.data_start;
    try file2.seekTo(decoder2.data_start);
    br2.start = 0;
    br2.end = 0;
    decoder3.counting_reader.bytes_read = decoder3.data_start;
    try file3.seekTo(decoder3.data_start);
    br3.start = 0;
    br3.end = 0;

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
