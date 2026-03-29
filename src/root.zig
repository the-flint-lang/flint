const std = @import("std");

const checker = @import("./core/helpers/utils/checkers.zig");
pub const IoHelper = @import("./core/helpers/structs/structs.zig").IoHelpers;
const Lexer = @import("./core/lexer/lexer.zig").Lexer;
const Parser = @import("./core/parser/parser.zig").Parser;
const TypeChecker = @import("./core/analyzer/type_checker.zig").TypeChecker;
const CEmitter = @import("./core/codegen/c_emitter.zig").CEmitter;
const AstNode = @import("./core/parser/ast.zig").AstNode;
const Token = @import("./core/lexer/structs/token.zig").Token;
const help = @import("./core/helpers/functions/help.zig").help;
const version = @import("./core/helpers/functions/version.zig").version;

const flint_rt_c_content = @embedFile("core/codegen/runtime/flint_rt.c");
const flint_rt_h_content = @embedFile("core/codegen/runtime/flint_rt.h");

var cached_compiler: ?Compiler = null;

const PipelineResult = struct {
    source: []const u8,
    tokens: []const Token,
    parser: Parser,
    ast: *AstNode,
};

fn runCompilerPipeline(
    alloc: std.mem.Allocator,
    file_path: []const u8,
    io: IoHelper,
) !PipelineResult {
    const source = try std.fs.cwd().readFileAlloc(alloc, file_path, 1024 * 1024);
    errdefer alloc.free(source);

    var lex = Lexer{
        .alloc = alloc,
        .io = io,
        .file_path = file_path,
        .position = 0,
        .column = 0,
        .line = 0,
        .tokens = .empty,
        .source = source,
    };
    const tokens = try lex.tokenize();

    var parser = Parser.init(alloc, tokens, source, file_path, io);

    const ast = parser.parse() catch {
        return error.ParseFailed;
    };

    var t_checker = try TypeChecker.init(alloc, file_path, source, io);
    try t_checker.check(ast);
    if (t_checker.had_error) return error.SemanticCheckFailed;

    return PipelineResult{
        .source = source,
        .tokens = tokens,
        .parser = parser,
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

    pub fn linkFile(self: *Linker, file_path: []const u8, current_alias: ?[]const u8) !void {
        const abs_path = std.fs.cwd().realpathAlloc(self.allocator, file_path) catch {
            try self.io.stderr.print("Fatal Error: Unable to import file '{s}'.\n", .{file_path});
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

        var local_stmts = std.ArrayList(*AstNode).empty;
        defer local_stmts.deinit(self.allocator);

        var local_aliases = std.StringHashMap([]const u8).init(self.allocator);
        defer local_aliases.deinit();

        for (result_ptr.ast.program.statements) |stmt| {
            if (stmt.* == .import_stmt) {
                const import_raw = stmt.import_stmt.path;
                const next_alias = stmt.import_stmt.alias;

                const basename = std.fs.path.basename(import_raw);
                const canon_name = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

                var formatted_path: []const u8 = undefined;

                if (!std.mem.endsWith(u8, import_raw, ".fl")) {
                    formatted_path = try std.fmt.allocPrint(self.allocator, "std/{s}.fl", .{import_raw});
                } else {
                    formatted_path = try self.allocator.dupe(u8, import_raw);
                }
                defer self.allocator.free(formatted_path);

                var next_file: []const u8 = undefined;

                if (std.mem.startsWith(u8, formatted_path, "./") or std.mem.startsWith(u8, formatted_path, "../")) {
                    next_file = try std.fs.path.join(self.allocator, &.{ base_dir, formatted_path });
                } else {
                    var std_base: []const u8 = "/usr/share/flint";

                    var dir = std.fs.cwd().openDir("std", .{});
                    if (std.posix.getenv("FLINT_LIB_PATH")) |env_path| {
                        std_base = env_path;
                    } else {
                        if (dir) |*dir_| {
                            dir_.close();
                            std_base = ".";
                        } else |_| {}
                    }

                    next_file = try std.fs.path.join(self.allocator, &.{ std_base, formatted_path });
                }

                defer self.allocator.free(next_file);

                try self.linkFile(next_file, canon_name);

                if (next_alias) |a| try local_aliases.put(a, canon_name);
            } else {
                try local_stmts.append(self.allocator, stmt);
            }
        }

        for (local_stmts.items) |stmt| {
            try self.resolveAliases(stmt, &local_aliases);
        }

        if (current_alias) |alias| {
            try self.applyNamespaces(local_stmts.items, alias);
        }

        for (local_stmts.items) |stmt| {
            try self.statements.append(self.allocator, stmt);
        }
    }

    fn applyNamespaces(self: *Linker, statements: []const *AstNode, alias: []const u8) !void {
        var local_symbols = std.StringHashMap(void).init(self.allocator);
        defer local_symbols.deinit();

        for (statements) |stmt| {
            if (stmt.* == .function_decl) {
                if (!stmt.function_decl.is_extern) try local_symbols.put(stmt.function_decl.name, {});
            } else if (stmt.* == .struct_decl) {
                try local_symbols.put(stmt.struct_decl.name, {});
            } else if (stmt.* == .var_decl) {
                try local_symbols.put(stmt.var_decl.name, {});
            }
            try self.walkAndPrefix(stmt, &local_symbols, alias);
        }

        for (statements) |stmt| {
            try self.walkAndPrefix(stmt, &local_symbols, alias);
        }

        for (statements) |stmt| {
            if (stmt.* == .function_decl) {
                if (!stmt.function_decl.is_extern) stmt.function_decl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, stmt.function_decl.name });
            } else if (stmt.* == .struct_decl) {
                stmt.struct_decl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, stmt.struct_decl.name });
            } else if (stmt.* == .var_decl) {
                stmt.var_decl.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, stmt.var_decl.name });
            }
        }
    }

    fn resolveAliases(self: *Linker, node: *AstNode, aliases: *std.StringHashMap([]const u8)) anyerror!void {
        switch (node.*) {
            .function_decl => |*f| {
                for (f.body) |stmt| try self.resolveAliases(stmt, aliases);
            },
            .if_stmt => |*i| {
                try self.resolveAliases(i.condition, aliases);
                for (i.then_branch) |stmt| try self.resolveAliases(stmt, aliases);
                if (i.else_branch) |eb| for (eb) |stmt| try self.resolveAliases(stmt, aliases);
            },
            .for_stmt => |*f| {
                try self.resolveAliases(f.iterable, aliases);
                for (f.body) |stmt| try self.resolveAliases(stmt, aliases);
            },
            .var_decl => |*v| try self.resolveAliases(v.value, aliases),
            .binary_expr => |*b| {
                try self.resolveAliases(b.left, aliases);
                try self.resolveAliases(b.right, aliases);
            },
            .unary_expr => |*u| try self.resolveAliases(u.right, aliases),
            .pipeline_expr => |*p| {
                try self.resolveAliases(p.left, aliases);
                try self.resolveAliases(p.right_call, aliases);
            },
            .call_expr => |*c| {
                try self.resolveAliases(c.callee, aliases);
                for (c.arguments) |arg| try self.resolveAliases(arg, aliases);
            },
            .catch_expr => |*c| {
                try self.resolveAliases(c.expression, aliases);
                for (c.body) |stmt| try self.resolveAliases(stmt, aliases);
            },
            .array_expr => |*a| {
                for (a.elements) |el| try self.resolveAliases(el, aliases);
            },
            .dict_expr => |*d| {
                for (d.entries) |entry| {
                    try self.resolveAliases(entry.key, aliases);
                    try self.resolveAliases(entry.value, aliases);
                }
            },
            .index_expr => |*i| {
                try self.resolveAliases(i.left, aliases);
                try self.resolveAliases(i.index, aliases);
            },
            .return_stmt => |*r| {
                if (r.value) |val| try self.resolveAliases(val, aliases);
            },
            .property_access_expr => |*p| {
                try self.resolveAliases(p.object, aliases);
                if (p.object.* == .identifier) {
                    if (aliases.get(p.object.identifier.name)) |canon_name| {
                        const new_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ canon_name, p.property_name });
                        node.* = .{
                            .identifier = .{
                                ._type = .{ ._type = .identifier_token, .value = new_name, .line = 0, .column = 0 },
                                .name = new_name,
                            },
                        };
                    }
                }
            },
            else => {},
        }
    }

    fn walkAndPrefix(self: *Linker, node: *AstNode, locals: *std.StringHashMap(void), alias: []const u8) anyerror!void {
        switch (node.*) {
            .function_decl => |*f| {
                for (f.body) |stmt| try self.walkAndPrefix(stmt, locals, alias);
            },
            .if_stmt => |*i| {
                try self.walkAndPrefix(i.condition, locals, alias);
                for (i.then_branch) |stmt| try self.walkAndPrefix(stmt, locals, alias);
                if (i.else_branch) |eb| {
                    for (eb) |stmt| try self.walkAndPrefix(stmt, locals, alias);
                }
            },
            .for_stmt => |*f| {
                try self.walkAndPrefix(f.iterable, locals, alias);
                for (f.body) |stmt| try self.walkAndPrefix(stmt, locals, alias);
            },
            .var_decl => |*v| try self.walkAndPrefix(v.value, locals, alias),
            .binary_expr => |*b| {
                try self.walkAndPrefix(b.left, locals, alias);
                try self.walkAndPrefix(b.right, locals, alias);
            },
            .unary_expr => |*u| try self.walkAndPrefix(u.right, locals, alias),
            .pipeline_expr => |*p| {
                try self.walkAndPrefix(p.left, locals, alias);
                try self.walkAndPrefix(p.right_call, locals, alias);
            },
            .call_expr => |*c| {
                if (c.callee.* == .identifier) {
                    const name = c.callee.identifier.name;

                    if (locals.contains(name)) {
                        c.callee.identifier.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, name });
                    }

                    if (std.mem.eql(u8, name, "parse_json_as") and c.arguments.len > 0) {
                        if (c.arguments[0].* == .identifier) {
                            const struct_name = c.arguments[0].identifier.name;
                            if (locals.contains(struct_name)) {
                                c.arguments[0].identifier.name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, struct_name });
                            }
                        }
                    }
                } else {
                    try self.walkAndPrefix(c.callee, locals, alias);
                }

                for (c.arguments) |arg| try self.walkAndPrefix(arg, locals, alias);
            },
            .catch_expr => |*c| {
                try self.walkAndPrefix(c.expression, locals, alias);
                for (c.body) |stmt| try self.walkAndPrefix(stmt, locals, alias);
            },
            .array_expr => |*a| {
                for (a.elements) |el| try self.walkAndPrefix(el, locals, alias);
            },
            .dict_expr => |*d| {
                for (d.entries) |entry| {
                    try self.walkAndPrefix(entry.key, locals, alias);
                    try self.walkAndPrefix(entry.value, locals, alias);
                }
            },
            .index_expr => |*i| {
                try self.walkAndPrefix(i.left, locals, alias);
                try self.walkAndPrefix(i.index, locals, alias);
            },
            .return_stmt => |*r| {
                if (r.value) |val| try self.walkAndPrefix(val, locals, alias);
            },
            .property_access_expr => |*p| try self.walkAndPrefix(p.object, locals, alias),
            .struct_decl, .import_stmt, .identifier, .literal => {}, // Nós folha, ignora
            else => {},
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

    if (checker.strEquals(cmd, "lex")) {
        const file_path = try getFlFile(&args, io);

        const source = try std.fs.cwd().readFileAlloc(alloc, file_path, 1024 * 1024);
        defer alloc.free(source);

        var lexer = Lexer{
            .alloc = alloc,
            .io = io,
            .file_path = file_path,
            .position = 0,
            .column = 0,
            .line = 0,
            .tokens = .empty,
            .source = source,
        };

        const tokens = lexer.tokenize() catch |err| {
            try io.stderr.print("Lexer error: {}\n", .{err});
            return;
        };
        defer alloc.free(tokens);

        for (tokens) |t| {
            const a = try t.toString(alloc);
            defer alloc.free(a);
            try io.stdout.print("{s}\n", .{a});
        }
        return;
    }

    if (checker.strEquals(cmd, "parse")) {
        const file_path = try getFlFile(&args, io);

        var result = runCompilerPipeline(alloc, file_path, io) catch return;
        defer alloc.free(result.source);
        defer result.parser.deinit();
        defer alloc.free(result.tokens);

        try io.stdout.print("Parser finished. AST generated successfully.\n", .{});
        return;
    }

    if (checker.strEquals(cmd, "build")) {
        const file_path = try getFlFile(&args, io);

        try runner(alloc, &args, file_path, io, false);
        return;
    }

    if (checker.strEquals(cmd, "run")) {
        const file_path = try getFlFile(&args, io);

        try runner(alloc, &args, file_path, io, true);
        return;
    }

    try help(io);
    try io.stderr.print("\n\x1b[1;31merror:\x1b[0m Unknown command '{s}'\n", .{cmd});
}

fn getFlFile(args: *std.process.ArgIterator, io: anytype) ![]const u8 {
    const file_path = args.next() orelse {
        try io.stderr.print("\x1b[1;31merror:\x1b[0m Provide the path of the .fl file\n", .{});
        return "";
    };

    if (std.mem.lastIndexOfScalar(u8, file_path, '.')) |idx| {
        const ext = file_path[idx..];
        if (!std.mem.eql(u8, ext, ".fl")) {
            try io.stderr.print("\x1b[1;31merror:\x1b[0m File must have a .fl extension\n", .{});
            return "";
        }
    }

    return file_path;
}

fn runner(alloc: std.mem.Allocator, args: *std.process.ArgIterator, file_path: []const u8, io: anytype, is_run: bool) !void {
    var linker = Linker.init(alloc, io);
    defer linker.deinit();

    linker.linkFile(file_path, null) catch {};
    if (linker.has_error) {
        try io.stderr.print("Syntax error while linking modules. Aborting build.\n", .{});
        return;
    }

    var merged_ast = AstNode{ .program = .{ .statements = linker.statements.items } };

    var emitter = CEmitter.init(alloc, file_path);
    const out_filename = try std.fmt.allocPrint(alloc, ".flint_temp_{x}.c", .{std.hash.Wyhash.hash(0, file_path)});
    defer alloc.free(out_filename);

    var out_file = try std.fs.cwd().createFile(out_filename, .{});
    var buffer: [4096]u8 = undefined;
    var out_writer = out_file.writer(&buffer);

    try emitter.generate(&out_writer.interface, &merged_ast);
    _ = out_writer.interface.flush() catch {};
    out_file.close();

    if (!is_run) {
        try io.stdout.print("\x1b[38;5;208m[FLINT]\x1b[0m Transpiling and compiling native binary...\n", .{});
        _ = try io.stdout.flush();
    }

    const basename = std.fs.path.basename(file_path);
    const exe_name = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

    var h_file = try std.fs.cwd().createFile("flint_rt.h", .{});
    try h_file.writeAll(flint_rt_h_content);
    h_file.close();

    var rt_path: []const u8 = "flint_rt.c";
    var using_precompiled = false;

    const system_rt_o = "/usr/share/flint/flint_rt.o";
    if (std.fs.cwd().access(system_rt_o, .{})) |_| {
        rt_path = system_rt_o;
        using_precompiled = true;
    } else |_| {
        var c_file = try std.fs.cwd().createFile("flint_rt.c", .{});
        try c_file.writeAll(flint_rt_c_content);
        c_file.close();
    }

    defer std.fs.cwd().deleteFile(out_filename) catch {};
    defer std.fs.cwd().deleteFile("flint_rt.h") catch {};

    if (!using_precompiled) {
        defer std.fs.cwd().deleteFile("flint_rt.c") catch {};
    }

    const compiler = getBestCCompiler(alloc);
    const c_args = switch (compiler) {
        .clang => |c| try c.getArgs(alloc, out_filename, exe_name, rt_path),
        .gcc => |g| try g.getArgs(alloc, out_filename, exe_name, rt_path),
    };
    defer alloc.free(c_args);

    var child = std.process.Child.init(c_args, alloc);

    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Inherit;

    const term = try child.spawnAndWait();

    switch (term) {
        .Exited => |code| {
            if (code == 0) {
                if (!is_run) {
                    try io.stdout.print("\x1b[1;32m[SUCCESS]\x1b[0m Executable '{s}' generated.\n", .{exe_name});
                }
            } else {
                try io.stderr.print("Fatal error in Native C Compiler (code {d}).\n", .{code});
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
        defer std.fs.cwd().deleteFile(exe_name) catch {};

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

    var walker = try test_dir.walk(alloc);
    defer walker.deinit();

    var pass_count: usize = 0;
    var fail_count: usize = 0;

    try io.stdout.print("\x1b[36m=== STARTING FLINT TEST BATTERY ===\x1b[0m\n\n", .{});
    _ = try io.stdout.flush();

    var h_file = try std.fs.cwd().createFile("flint_rt.h", .{});
    try h_file.writeAll(flint_rt_h_content);
    h_file.close();

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".fl")) {
            const file_path = try std.fmt.allocPrint(alloc, "tests/{s}", .{entry.path});
            defer alloc.free(file_path);

            const passed = try testSingleFile(alloc, file_path, io);

            if (passed) {
                try io.stdout.print("\x1b[32m[PASS]\x1b[0m {s}\n", .{entry.path});
                pass_count += 1;
            } else {
                try io.stdout.print("\x1b[31m[FAIL]\x1b[0m {s}\n", .{entry.path});
                fail_count += 1;
            }
            _ = try io.stdout.flush();
        }
    }

    std.fs.cwd().deleteFile("flint_rt.h") catch {};
    try io.stdout.print("\n---------------------------------------\n", .{});
    try io.stdout.print("Total: {d} | \x1b[32mPassed: {d}\x1b[0m | \x1b[31mFailed: {d}\x1b[0m\n\n", .{ pass_count + fail_count, pass_count, fail_count });
}

fn testSingleFile(alloc: std.mem.Allocator, file_path: []const u8, io: IoHelper) !bool {
    var linker = Linker.init(alloc, io);
    defer linker.deinit();

    linker.linkFile(file_path, null) catch {};
    if (linker.has_error) return false;

    var merged_ast = AstNode{ .program = .{ .statements = linker.statements.items } };

    var emitter = CEmitter.init(alloc, file_path);

    const basename = std.fs.path.basename(file_path);
    const name_only = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

    const out_filename = try std.fmt.allocPrint(alloc, ".flint_temp_{x}.c", .{std.hash.Wyhash.hash(0, file_path)});
    defer alloc.free(out_filename);
    const exe_name = try std.fmt.allocPrint(alloc, ".bin_test_{s}", .{name_only});
    defer alloc.free(exe_name);

    var out_file = try std.fs.cwd().createFile(out_filename, .{});
    var buffer: [4096]u8 = undefined;
    var out_writer = out_file.writer(&buffer);

    try emitter.generate(&out_writer.interface, &merged_ast);
    _ = out_writer.interface.flush() catch {};
    out_file.close();

    // var h_file = try std.fs.cwd().createFile("flint_rt.h", .{});
    // try h_file.writeAll(flint_rt_h_content);
    // h_file.close();
    // defer std.fs.cwd().deleteFile("flint_rt.h") catch {};

    var rt_path: []const u8 = "flint_rt.c";
    var using_precompiled = false;

    const system_rt_o = "/usr/share/flint/flint_rt.o";
    if (std.fs.cwd().access(system_rt_o, .{})) |_| {
        rt_path = system_rt_o;
        using_precompiled = true;
    } else |_| {
        var c_file = try std.fs.cwd().createFile("flint_rt.c", .{});
        try c_file.writeAll(flint_rt_c_content);
        c_file.close();
    }

    defer std.fs.cwd().deleteFile(out_filename) catch {};
    // defer std.fs.cwd().deleteFile("flint_rt.h") catch {};

    if (!using_precompiled) {
        defer std.fs.cwd().deleteFile("flint_rt.c") catch {};
    }

    const compiler = getBestCCompiler(alloc);

    const args = switch (compiler) {
        .clang => |c| try c.getArgs(alloc, out_filename, exe_name, rt_path),
        .gcc => |g| try g.getArgs(alloc, out_filename, exe_name, rt_path),
    };
    defer alloc.free(args);

    var child_clang = std.process.Child.init(args, alloc);
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

    std.fs.cwd().deleteFile(exe_name) catch {};
    return run_term == .Exited and run_term.Exited == 0;
}

const ClangCompiler = struct {
    pub fn getArgs(self: ClangCompiler, alloc: std.mem.Allocator, out_filename: []const u8, exe_name: []const u8, rt_path: []const u8) ![]const []const u8 {
        _ = self;
        const args = try alloc.alloc([]const u8, 10);
        args[0] = "clang";
        args[1] = out_filename;
        args[2] = rt_path;
        args[3] = "-I.";
        args[4] = "-lcurl";
        args[5] = "-s";
        args[6] = "-o";
        args[7] = exe_name;
        args[8] = "-O3";
        args[9] = "-march=native";
        return args;
    }
};

const GccCompiler = struct {
    pub fn getArgs(self: GccCompiler, alloc: std.mem.Allocator, out_filename: []const u8, exe_name: []const u8, rt_path: []const u8) ![]const []const u8 {
        _ = self;
        const args = try alloc.alloc([]const u8, 10);
        args[0] = "gcc";
        args[1] = out_filename;
        args[2] = rt_path;
        args[3] = "-I.";
        args[4] = "-lcurl";
        args[5] = "-s";
        args[6] = "-o";
        args[7] = exe_name;
        args[8] = "-O3";
        args[9] = "-march=native";
        return args;
    }
};

pub const Compiler = union(enum) {
    clang: ClangCompiler,
    gcc: GccCompiler,

    pub fn getName(self: Compiler) []const u8 {
        return switch (self) {
            .clang => "clang",
            .gcc => "gcc",
        };
    }
};

fn getBestCCompiler(alloc: std.mem.Allocator) Compiler {
    if (cached_compiler) |c| return c;

    const result: Compiler = blk: {
        if (isCompilerPresent(alloc, "clang")) break :blk .{ .clang = ClangCompiler{} };
        if (isCompilerPresent(alloc, "gcc")) break :blk .{ .gcc = GccCompiler{} };
        break :blk .{ .clang = ClangCompiler{} }; // fallback
    };

    cached_compiler = result;
    return result;
}

fn isCompilerPresent(alloc: std.mem.Allocator, cmd: []const u8) bool {
    const path_env = std.process.getEnvVarOwned(alloc, "PATH") catch return false;
    defer alloc.free(path_env);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const full = std.fs.path.join(alloc, &.{ dir, cmd }) catch continue;
        defer alloc.free(full);

        std.posix.access(full, std.posix.X_OK) catch continue;
        return true;
    }

    return false;
}
