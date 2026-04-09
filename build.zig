const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const opts = b.addOptions();
    opts.addOption([]const u8, "flint_version", "1.10.0");

    const mod = b.addModule("flint", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = opts.createModule() },
        },
    });

    const exe = b.addExecutable(.{
        .name = "flint",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "flint", .module = mod },
            },
        }),
    });
    mod.addIncludePath(.{ .cwd_relative = "/usr/include" });
    mod.addLibraryPath(.{ .cwd_relative = "/usr/lib/x86_64-linux-gnu" });
    mod.linkSystemLibrary("tcc", .{ .preferred_link_mode = .static });

    exe.linkLibC();

    // new improvments to low size binary
    exe.stack_size = 1 * 1024 * 1024;
    exe.compress_debug_sections = .zstd;
    exe.root_module.unwind_tables = .none;

    exe.root_module.strip = true;
    exe.link_gc_sections = true;
    exe.want_lto = true;

    b.installArtifact(exe);

    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());

    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
