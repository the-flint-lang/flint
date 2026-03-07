const std = @import("std");

//utils
const checker = @import("./helpers/utils/checkers.zig");

// structs
const IoHelper = @import("./helpers/structs/structs.zig").IoHelpers;

// functions
const help = @import("./helpers/functions/help.zig").help;
const version = @import("./helpers/functions/version.zig").version;

pub fn bufferedPrint(alloc: std.mem.Allocator) !void {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;

    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    defer {
        _ = stdout_writer.interface.flush() catch {};
        _ = stderr_writer.interface.flush() catch {};
    }

    const io = IoHelper{
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    };

    var command: ?[]const u8 = null;

    while (args.next()) |arg| {
        if (checker.cliArgsEquals(arg, &.{ "-h", "--help" })) {
            try help(io);
            return;
        }

        if (checker.cliArgsEquals(arg, &.{ "-V", "--version" })) {
            try version(io);
            return;
        }

        command = arg;
        break;
    }

    const cmd = command orelse {
        try help(io);

        return;
    };

    if (checker.strEquals(cmd, "build")) {
        try io.stdout.print("Building\n", .{});
        _ = io.stdout.flush() catch {};

        return;
    }

    try help(io);
    try io.stderr.print("\nUnknow command: '{s}'\n", .{cmd});
    _ = io.stderr.flush() catch {};
}
