const std = @import("std");

//utils
const checker = @import("./core/helpers/utils/checkers.zig");

// structs
const IoHelper = @import("./core/helpers/structs/structs.zig").IoHelpers;
const Lexer = @import("./core/lexer/lexer.zig").Lexer;
const Parser = @import("./core/parser/parser.zig").Parser;
const CEmitter = @import("./core/codegen/c_emitter.zig").CEmitter;

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
        const file_path = args.next() orelse {
            try io.stderr.print("Erro: Forneça o caminho do arquivo .fl\n", .{});
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
        const tokens = try lex.tokenize();

        var parse = Parser.init(alloc, tokens, io);
        parse.allocator = parse.arena.allocator();
        const ast = parse.parse() catch {
            try io.stderr.print("Erro de sintaxe ao compilar.\n", .{});
            return;
        };
        defer parse.deinit();

        var emitter = CEmitter.init(alloc);
        const out_filename = ".flint_temp.c";

        var out_file = try std.fs.cwd().createFile(out_filename, .{});
        var buffer: [4096]u8 = undefined;

        var out_writer = out_file.writer(&buffer); // store in var
        try emitter.generate(&out_writer.interface, ast); // pass mutable pointer

        _ = out_writer.interface.flush() catch {}; // flush before close
        out_file.close();

        try io.stdout.print("Transpilado. Compilando binário nativo...\n", .{});
        _ = try io.stdout.flush();

        const basename = std.fs.path.basename(file_path);
        const exe_name = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

        const home_dir = std.process.getEnvVarOwned(alloc, "HOME") catch |err| {
            std.debug.print("Erro ao encontrar diretório home: {}\n", .{err});
            return;
        };
        defer alloc.free(home_dir); // Sempre libere a memória

        const path = try std.fmt.allocPrint(alloc, "{s}{s}", .{ home_dir, "/flint/src/core/codegen/runtime" });
        defer alloc.free(path);

        const argv = &[_][]const u8{
            "clang",
            out_filename,
            "/home/lucas/flint/src/core/codegen/runtime/flint_rt.c",
            "-I",
            path,
            "-o",
            exe_name,
            "-O3",
        };

        var child = std.process.Child.init(argv, alloc);
        const term = try child.spawnAndWait();

        switch (term) {
            .Exited => |code| {
                if (code == 0) {
                    try io.stdout.print("Sucesso! Executável '{s}' gerado.\n", .{exe_name});
                    try std.fs.cwd().deleteFile(out_filename);
                } else {
                    try io.stderr.print("Erro fatal no Clang (código {d}). O código C gerado falhou.\n", .{code});
                }
            },
            else => {
                try io.stderr.print("O compilador C falhou ou foi interrompido inesperadamente.\n", .{});
            },
        }

        _ = try io.stdout.flush();
        _ = try io.stderr.flush();
        return;
    }

    if (checker.strEquals(cmd, "parse")) {
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

        const tokens = try lex.tokenize();

        var parse = Parser.init(alloc, tokens, io);
        parse.allocator = parse.arena.allocator();

        _ = parse.parse() catch |err| {
            try io.stderr.print("Erro ao parsear> {}\n", .{err});

            _ = try io.stderr.flush();
            return;
        };

        try io.stdout.print("tudo ok\n", .{});
        _ = try io.stdout.flush();

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

        const tokens = try lex.tokenize();

        for (tokens) |t| {
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
