const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root_module = b.createModule(.{
        .root_source_file = b.path("zig-src/main.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    const exe = b.addExecutable(.{
        .name = "code-scanner",
        .root_module = root_module,
    });

    // Prefer a single-file binary.
    // Notes:
    // - On Windows, "fully static" still depends on system DLLs (kernel32, etc.).
    // - To avoid MSVC/UCRT runtime DLL dependency, build for windows-gnu and force static linkage.
    if (target.result.os.tag == .windows and target.result.abi == .gnu) {
        exe.linkage = .static;
    }

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run code-scanner");
    run_step.dependOn(&run_cmd.step);
}
