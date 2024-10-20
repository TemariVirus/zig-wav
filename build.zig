const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Make module available as dependency.
    const lib = b.addModule("wav", .{ .root_source_file = b.path("src/wav.zig") });

    const exe = b.addExecutable(.{
        .name = "zig-wav",
        .root_source_file = b.path("src/a.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe.root_module.addImport("wav", lib);
    const install_step = b.addInstallArtifact(exe, .{});

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_step.dependOn(&install_step.step);

    const test_step = b.step("test", "Run library tests");
    inline for ([_][]const u8{ "src/sample.zig", "src/wav.zig" }) |test_file| {
        const t = b.addTest(.{
            .root_source_file = b.path(test_file),
            .target = target,
            .optimize = optimize,
        });
        const run_test = b.addRunArtifact(t);
        test_step.dependOn(&run_test.step);
    }
}
