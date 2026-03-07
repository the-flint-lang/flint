const std = @import("std");

//utils
const checker = @import("./core/helpers/utils/checkers.zig");

// structs
const IoHelper = @import("./core/helpers/structs/structs.zig").IoHelpers;
const Lexer = @import("./core/lexer/lexer.zig").Lexer;

// functions
const help = @import("./core/helpers/functions/help.zig").help;
const version = @import("./core/helpers/functions/version.zig").version;

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

    if (checker.strEquals(cmd, "lex")) {
        const file_path = args.next() orelse {
            try io.stderr.print("Erro: Forneça o caminho do arquivo .flt\n", .{});
            std.process.exit(1);
        };

        const source = try std.fs.cwd().readFileAlloc(alloc, file_path, 1024 * 1024);
        defer alloc.free(source);

        var lex = Lexer{
            .alloc = alloc,
            .io = io,

            .position = 0,
            .column = 0,
            .line = 0,

            .tokens = .empty,
            .source = source,
        };

        var tokens = try lex.tokenize();
        defer tokens.deinit(alloc);

        for (tokens.items) |t| {
            const a = try t.toString(alloc);

            try io.stderr.print("{s}\n", .{a});
            _ = io.stdout.flush() catch {};
        }

        return;
    }

    try help(io);
    try io.stderr.print("\nUnknow command: '{s}'\n", .{cmd});
    _ = io.stderr.flush() catch {};
}
