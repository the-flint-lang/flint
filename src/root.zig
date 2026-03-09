const std = @import("std");

const checker = @import("./core/helpers/utils/checkers.zig");
pub const IoHelper = @import("./core/helpers/structs/structs.zig").IoHelpers;
const Lexer = @import("./core/lexer/lexer.zig").Lexer;
const Parser = @import("./core/parser/parser.zig").Parser;
const CEmitter = @import("./core/codegen/c_emitter.zig").CEmitter;
const AstNode = @import("./core/parser/ast.zig").AstNode;
const Token = @import("./core/lexer/structs/token.zig").Token;
const help = @import("./core/helpers/functions/help.zig").help;
const version = @import("./core/helpers/functions/version.zig").version;

// Injetando o código C diretamente no executável do Zig!
const flint_rt_c_content = @embedFile("core/codegen/runtime/flint_rt.c");
const flint_rt_h_content = @embedFile("core/codegen/runtime/flint_rt.h");

const PipelineResult = struct {
    source: []const u8,
    tokens: []const Token,
    parser: Parser,
    ast: *AstNode,
};

fn runCompilerPipeline(alloc: std.mem.Allocator, file_path: []const u8, io: IoHelper) !PipelineResult {
    const source = try std.fs.cwd().readFileAlloc(alloc, file_path, 1024 * 1024);
    errdefer alloc.free(source);

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

    var parse = Parser.init(alloc, tokens, source, file_path, io);
    parse.allocator = parse.arena.allocator();

    const ast = parse.parse() catch {
        return error.ParseFailed;
    };

    return PipelineResult{
        .source = source,
        .tokens = tokens,
        .parser = parse,
        .ast = ast,
    };
}

const Linker = struct {
    allocator: std.mem.Allocator,
    visited: std.StringHashMap(void),
    statements: std.ArrayList(*AstNode),
    results: std.ArrayList(*PipelineResult),
    io: IoHelper,
    has_error: bool = false,

    pub fn init(alloc: std.mem.Allocator, io: IoHelper) Linker {
        return .{
            .allocator = alloc,
            .visited = std.StringHashMap(void).init(alloc),
            .statements = std.ArrayList(*AstNode).empty,
            .results = std.ArrayList(*PipelineResult).empty,
            .io = io,
        };
    }

    pub fn deinit(self: *Linker) void {
        var it = self.visited.keyIterator();
        while (it.next()) |key| {
            self.allocator.free(key.*);
        }
        self.visited.deinit();

        for (self.results.items) |res_ptr| {
            self.allocator.free(res_ptr.source);
            self.allocator.free(res_ptr.tokens);
            res_ptr.parser.deinit();
            self.allocator.destroy(res_ptr);
        }
        self.results.deinit(self.allocator);
        self.statements.deinit(self.allocator);
    }

    pub fn linkFile(self: *Linker, file_path: []const u8) !void {
        const abs_path = std.fs.cwd().realpathAlloc(self.allocator, file_path) catch {
            try self.io.stderr.print("Erro Fatal: Nao foi possivel importar o arquivo '{s}'.\n", .{file_path});
            self.has_error = true;
            return;
        };
        defer self.allocator.free(abs_path);

        if (self.visited.contains(abs_path)) return;

        const path_dup = try self.allocator.dupe(u8, abs_path);
        try self.visited.put(path_dup, {});

        const result_ptr = try self.allocator.create(PipelineResult);
        result_ptr.* = runCompilerPipeline(self.allocator, file_path, self.io) catch {
            self.has_error = true;
            return;
        };
        try self.results.append(self.allocator, result_ptr);

        if (result_ptr.parser.had_error) {
            self.has_error = true;
            return;
        }

        const base_dir = std.fs.path.dirname(file_path) orelse ".";

        for (result_ptr.ast.program.statements) |stmt| {
            if (stmt.* == .import_stmt) {
                const import_raw = stmt.import_stmt.path;
                const clean_path = import_raw[0..import_raw.len];

                const next_file = try std.fs.path.join(self.allocator, &.{ base_dir, clean_path });
                defer self.allocator.free(next_file);

                try self.linkFile(next_file);
            } else {
                try self.statements.append(self.allocator, stmt);
            }
        }
    }
};

pub fn runCli(alloc: std.mem.Allocator, io: IoHelper) !void {
    var args = try std.process.argsWithAllocator(alloc);
    defer args.deinit();

    _ = args.next();

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

    if (checker.strEquals(cmd, "test")) {
        try runTests(alloc, io);
        return;
    }

    const file_path = args.next() orelse {
        try io.stderr.print("Error: Provide the path of the .fl file\n", .{});
        return;
    };

    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |idx| {
        const ext = file_path[idx..];
        if (!std.mem.eql(u8, ext, ".fl")) {
            try io.stderr.print("Error: Provide a .fl file\n", .{});
            return;
        }
    }

    if (checker.strEquals(cmd, "lex")) {
        var result = runCompilerPipeline(alloc, file_path, io) catch return;
        defer alloc.free(result.source);
        defer result.parser.deinit();
        defer alloc.free(result.tokens);

        for (result.tokens) |t| {
            const a = try t.toString(alloc);
            defer alloc.free(a);
            try io.stdout.print("{s}\n", .{a});
        }
        return;
    }

    if (checker.strEquals(cmd, "parse")) {
        var result = runCompilerPipeline(alloc, file_path, io) catch return;
        defer alloc.free(result.source);
        defer result.parser.deinit();
        defer alloc.free(result.tokens);

        try io.stdout.print("Parser finished. AST generated successfully.\n", .{});
        return;
    }

    if (checker.strEquals(cmd, "build")) {
        try runner(alloc, &args, file_path, io, false);
        return;
    }

    if (checker.strEquals(cmd, "run")) {
        try runner(alloc, &args, file_path, io, true);
        return;
    }

    try help(io);
    try io.stderr.print("\nUnknown command: '{s}'\n", .{cmd});
}

fn runner(alloc: std.mem.Allocator, args: *std.process.ArgIterator, file_path: []const u8, io: anytype, is_run: bool) !void {
    var linker = Linker.init(alloc, io);
    defer linker.deinit();

    linker.linkFile(file_path) catch {};
    if (linker.has_error) {
        try io.stderr.print("Syntax error while linking modules. Aborting build.\n", .{});
        return;
    }

    var merged_ast = AstNode{ .program = .{ .statements = linker.statements.items } };

    var emitter = CEmitter.init(alloc);
    const out_filename = ".flint_temp.c";

    var out_file = try std.fs.cwd().createFile(out_filename, .{});
    var buffer: [4096]u8 = undefined;
    var out_writer = out_file.writer(&buffer);

    try emitter.generate(&out_writer.interface, &merged_ast);
    _ = out_writer.interface.flush() catch {};
    out_file.close();

    if (!is_run) {
        try io.stdout.print("Transpiled. Compiling native binary...\n", .{});
        _ = try io.stdout.flush();
    }

    const basename = std.fs.path.basename(file_path);
    const exe_name = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

    var h_file = try std.fs.cwd().createFile("flint_rt.h", .{});
    try h_file.writeAll(flint_rt_h_content);
    h_file.close();

    var c_file = try std.fs.cwd().createFile("flint_rt.c", .{});
    try c_file.writeAll(flint_rt_c_content);
    c_file.close();

    defer std.fs.cwd().deleteFile("flint_rt.h") catch {};
    defer std.fs.cwd().deleteFile("flint_rt.c") catch {};

    const argv = &[_][]const u8{
        "clang",
        out_filename,
        "flint_rt.c",
        "-I.",
        "-lcurl",
        "-s",
        "-o",
        exe_name,
        "-O3",
    };

    var child = std.process.Child.init(argv, alloc);
    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                if (!is_run) {
                    try io.stdout.print("Success! Executable '{s}' generated.\n", .{exe_name});
                }
                std.fs.cwd().deleteFile(out_filename) catch {};
            } else {
                try io.stderr.print("Fatal error in Clang (code {d}).\n", .{code});
                return;
            }
        },
        else => {
            try io.stderr.print("The C compiler failed unexpectedly.\n", .{});
            return;
        },
    }

    if (is_run) {
        const exec_path = try std.fmt.allocPrint(alloc, "./{s}", .{exe_name});
        defer alloc.free(exec_path);

        var run_args = std.ArrayList([]const u8).empty;
        defer run_args.deinit(alloc);

        try run_args.append(alloc, exec_path);

        while (args.next()) |arg| {
            try run_args.append(alloc, arg);
        }

        var child_run = std.process.Child.init(run_args.items, alloc);
        const term_run = try child_run.spawnAndWait();

        switch (term_run) {
            .Exited => |code| {
                if (code != 0) {
                    try io.stderr.print("Process exited with code {d}.\n", .{code});
                }
            },
            else => try io.stderr.print("Unexpected execution error.\n", .{}),
        }
    }
}

fn runTests(alloc: std.mem.Allocator, io: IoHelper) !void {
    var test_dir = std.fs.cwd().openDir("tests", .{ .iterate = true }) catch |err| {
        try io.stderr.print("Fatal error: Unable to open 'tests' folder ({any}).\n", .{err});
        return;
    };
    defer test_dir.close();

    var iter = test_dir.iterate();
    var pass_count: usize = 0;
    var fail_count: usize = 0;

    try io.stdout.print("\x1b[36m=== STARTING FLINT TEST BATTERY ===\x1b[0m\n\n", .{});
    _ = try io.stdout.flush();

    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".fl")) {
            const file_path = try std.fmt.allocPrint(alloc, "tests/{s}", .{entry.name});
            defer alloc.free(file_path);

            const passed = try testSingleFile(alloc, file_path, io);

            if (passed) {
                try io.stdout.print("\x1b[32m[PASS]\x1b[0m {s}\n", .{entry.name});
                pass_count += 1;
            } else {
                try io.stdout.print("\x1b[31m[FAIL]\x1b[0m {s}\n", .{entry.name});
                fail_count += 1;
            }
            _ = try io.stdout.flush();
        }
    }

    try io.stdout.print("\n---------------------------------------\n", .{});
    try io.stdout.print("Total: {d} | \x1b[32mPassed: {d}\x1b[0m | \x1b[31mFailed: {d}\x1b[0m\n\n", .{ pass_count + fail_count, pass_count, fail_count });
}

fn testSingleFile(alloc: std.mem.Allocator, file_path: []const u8, io: IoHelper) !bool {
    var linker = Linker.init(alloc, io);
    defer linker.deinit();

    linker.linkFile(file_path) catch {};
    if (linker.has_error) return false;

    var merged_ast = AstNode{ .program = .{ .statements = linker.statements.items } };

    var emitter = CEmitter.init(alloc);

    const basename = std.fs.path.basename(file_path);
    const name_only = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

    const out_filename = try std.fmt.allocPrint(alloc, ".temp_test_{s}.c", .{name_only});
    defer alloc.free(out_filename);
    const exe_name = try std.fmt.allocPrint(alloc, ".bin_test_{s}", .{name_only});
    defer alloc.free(exe_name);

    var out_file = try std.fs.cwd().createFile(out_filename, .{});
    var buffer: [4096]u8 = undefined;
    var out_writer = out_file.writer(&buffer);

    try emitter.generate(&out_writer.interface, &merged_ast);
    _ = out_writer.interface.flush() catch {};
    out_file.close();

    defer std.fs.cwd().deleteFile(out_filename) catch {};
    defer std.fs.cwd().deleteFile(exe_name) catch {};

    var h_file = try std.fs.cwd().createFile("flint_rt.h", .{});
    try h_file.writeAll(flint_rt_h_content);
    h_file.close();

    var c_file = try std.fs.cwd().createFile("flint_rt.c", .{});
    try c_file.writeAll(flint_rt_c_content);
    c_file.close();

    defer std.fs.cwd().deleteFile("flint_rt.h") catch {};
    defer std.fs.cwd().deleteFile("flint_rt.c") catch {};

    const clang_argv = &[_][]const u8{
        "clang",
        out_filename,
        "flint_rt.c",
        "-I.",
        "-lcurl",
        "-s",
        "-o",
        exe_name,
        "-O3",
    };

    var child_clang = std.process.Child.init(clang_argv, alloc);
    child_clang.stdout_behavior = .Ignore;
    child_clang.stderr_behavior = .Ignore;

    const clang_term = try child_clang.spawnAndWait();
    if (clang_term != .Exited or clang_term.Exited != 0) return false;

    const exec_path = try std.fmt.allocPrint(alloc, "./{s}", .{exe_name});
    defer alloc.free(exec_path);

    const run_argv = &[_][]const u8{exec_path};
    var child_run = std.process.Child.init(run_argv, alloc);
    child_run.stdout_behavior = .Ignore;
    child_run.stderr_behavior = .Ignore;

    const run_term = try child_run.spawnAndWait();
    return run_term == .Exited and run_term.Exited == 0;
}
