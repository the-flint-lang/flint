const std = @import("std");

const tcc = @cImport({
    @cInclude("libtcc.h");
});

const checker = @import("./core/helpers/utils/checkers.zig");
pub const IoHelper = @import("./core/helpers/structs/structs.zig").IoHelpers;
const Lexer = @import("./core/lexer/lexer.zig").Lexer;
const Parser = @import("./core/parser/parser.zig").Parser;
const TypeChecker = @import("./core/analyzer/type_checker.zig").TypeChecker;
const ast = @import("./core/parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const AstTree = ast.AstTree;
const StringPool = ast.StringPool;
const CEmitter = @import("./core/codegen/c_emitter.zig").CEmitter;
const AstNode = ast.AstNode;
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
    root_idx: NodeIndex,
};

fn runCompilerPipeline(alloc: std.mem.Allocator, tree: *AstTree, pool: *StringPool, file_path: []const u8, io: IoHelper) !PipelineResult {
    if (!std.mem.endsWith(u8, file_path, ".fl")) {
        return error.InvalidFileType;
    }

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

    var parser = Parser.init(alloc, tree, pool, tokens, source, file_path, io);
    const root_idx = try parser.parse();

    var t_checker = try TypeChecker.init(alloc, tree, pool, file_path, source, io);
    try t_checker.check(root_idx);

    if (t_checker.had_error) {
        parser.deinit();
        return error.SemanticCheckFailed;
    }

    return PipelineResult{
        .source = source,
        .tokens = tokens,
        .parser = parser,
        .root_idx = root_idx,
    };
}

const Linker = struct {
    allocator: std.mem.Allocator,
    tree: *AstTree,
    pool: *StringPool,
    visited: std.StringHashMap(void),
    statements: std.ArrayList(NodeIndex),
    results: std.ArrayList(*PipelineResult),
    io: IoHelper,
    has_error: bool = false,

    pub fn init(alloc: std.mem.Allocator, tree: *AstTree, pool: *StringPool, io: IoHelper) Linker {
        return .{
            .allocator = alloc,
            .tree = tree,
            .pool = pool,
            .visited = std.StringHashMap(void).init(alloc),
            .statements = std.ArrayList(NodeIndex).empty,
            .results = std.ArrayList(*PipelineResult).empty,
            .io = io,
        };
    }

    pub fn deinit(self: *Linker) void {
        var it = self.visited.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
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
        try self.visited.put(try self.allocator.dupe(u8, abs_path), {});

        const result_ptr = try self.allocator.create(PipelineResult);
        result_ptr.* = runCompilerPipeline(self.allocator, self.tree, self.pool, file_path, self.io) catch {
            self.has_error = true;
            return;
        };
        try self.results.append(self.allocator, result_ptr);

        if (result_ptr.parser.had_error) {
            self.has_error = true;
            return;
        }

        const base_dir = std.fs.path.dirname(file_path) orelse ".";
        var local_stmts = std.ArrayList(NodeIndex).empty;
        defer local_stmts.deinit(self.allocator);
        var local_aliases = std.StringHashMap([]const u8).init(self.allocator);
        defer local_aliases.deinit();

        const program_node = self.tree.getNode(result_ptr.root_idx);

        for (program_node.program.statements) |stmt_idx| {
            const stmt = self.tree.getNode(stmt_idx);

            if (stmt == .import_stmt) {
                const import_raw = stmt.import_stmt.path;
                const next_alias_id = stmt.import_stmt.alias_id;

                const next_alias_str = if (next_alias_id) |id| self.pool.get(id) else null;

                const basename = std.fs.path.basename(import_raw);
                const canon_name = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

                const formatted_path = if (!std.mem.endsWith(u8, import_raw, ".fl"))
                    try std.fmt.allocPrint(self.allocator, "std/{s}.fl", .{import_raw})
                else
                    try self.allocator.dupe(u8, import_raw);
                defer self.allocator.free(formatted_path);

                const next_file = if (std.mem.startsWith(u8, formatted_path, "./") or std.mem.startsWith(u8, formatted_path, "../"))
                    try std.fs.path.join(self.allocator, &.{ base_dir, formatted_path })
                else blk: {
                    var std_base: []const u8 = "/usr/share/flint";
                    if (std.posix.getenv("FLINT_LIB_PATH")) |env| {
                        std_base = env;
                    } else if (std.fs.cwd().openDir("std", .{})) |d| {
                        var dir = d;
                        dir.close();
                        std_base = ".";
                    } else |_| {}
                    break :blk try std.fs.path.join(self.allocator, &.{ std_base, formatted_path });
                };
                defer self.allocator.free(next_file);

                try self.linkFile(next_file, canon_name);
                if (next_alias_str) |a| try local_aliases.put(a, canon_name);
            } else {
                try local_stmts.append(self.allocator, stmt_idx);
            }
        }

        for (local_stmts.items) |stmt_idx| try self.resolveAliases(&result_ptr.parser, stmt_idx, &local_aliases);
        if (current_alias) |alias| try self.applyNamespaces(&result_ptr.parser, local_stmts.items, alias);

        for (local_stmts.items) |stmt_idx| try self.statements.append(self.allocator, stmt_idx);
    }

    fn applyNamespaces(self: *Linker, parser: *Parser, statements: []const NodeIndex, alias: []const u8) !void {
        var local_symbols = std.StringHashMap(void).init(self.allocator);
        defer local_symbols.deinit();

        for (statements) |stmt_idx| {
            const stmt = parser.tree.getNode(stmt_idx);
            if (stmt == .function_decl and !stmt.function_decl.is_extern) {
                try local_symbols.put(self.pool.get(stmt.function_decl.name_id), {});
            } else if (stmt == .struct_decl) {
                try local_symbols.put(self.pool.get(stmt.struct_decl.name_id), {});
            } else if (stmt == .var_decl) {
                try local_symbols.put(self.pool.get(stmt.var_decl.name_id), {});
            }
        }
        for (statements) |stmt_idx| {
            try self.walkAndPrefix(parser, stmt_idx, &local_symbols, alias);
            var node_ptr = &parser.tree.nodes.items[stmt_idx];

            if (node_ptr.* == .function_decl and !node_ptr.function_decl.is_extern) {
                const old_name = self.pool.get(node_ptr.function_decl.name_id);
                const new_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, old_name });
                node_ptr.function_decl.name_id = try self.pool.intern(self.allocator, new_name);
            } else if (node_ptr.* == .struct_decl) {
                const old_name = self.pool.get(node_ptr.struct_decl.name_id);
                const new_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, old_name });
                node_ptr.struct_decl.name_id = try self.pool.intern(self.allocator, new_name);
            } else if (node_ptr.* == .var_decl) {
                const old_name = self.pool.get(node_ptr.var_decl.name_id);
                const new_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, old_name });
                node_ptr.var_decl.name_id = try self.pool.intern(self.allocator, new_name);
            }
        }
    }

    fn resolveAliases(self: *Linker, parser: *Parser, idx: NodeIndex, aliases: *std.StringHashMap([]const u8)) anyerror!void {
        const node = parser.tree.getNode(idx);
        switch (node) {
            .function_decl => |f| for (f.body) |s| try self.resolveAliases(parser, s, aliases),
            .if_stmt => |i| {
                try self.resolveAliases(parser, i.condition, aliases);
                for (i.then_branch) |s| try self.resolveAliases(parser, s, aliases);
                if (i.else_branch) |eb| for (eb) |s| try self.resolveAliases(parser, s, aliases);
            },
            .for_stmt => |f| {
                try self.resolveAliases(parser, f.iterable, aliases);
                for (f.body) |s| try self.resolveAliases(parser, s, aliases);
            },
            .var_decl => |v| try self.resolveAliases(parser, v.value, aliases),
            .binary_expr => |b| {
                try self.resolveAliases(parser, b.left, aliases);
                try self.resolveAliases(parser, b.right, aliases);
            },
            .unary_expr => |u| try self.resolveAliases(parser, u.right, aliases),
            .pipeline_expr => |p| {
                try self.resolveAliases(parser, p.left, aliases);
                try self.resolveAliases(parser, p.right_call, aliases);
            },
            .call_expr => |c| {
                try self.resolveAliases(parser, c.callee, aliases);
                for (c.arguments) |a| try self.resolveAliases(parser, a, aliases);
            },
            .catch_expr => |c| {
                try self.resolveAliases(parser, c.expression, aliases);
                for (c.body) |s| try self.resolveAliases(parser, s, aliases);
            },
            .array_expr => |a| for (a.elements) |e| try self.resolveAliases(parser, e, aliases),
            .dict_expr => |d| for (d.entries) |e| {
                try self.resolveAliases(parser, e.key, aliases);
                try self.resolveAliases(parser, e.value, aliases);
            },
            .index_expr => |i| {
                try self.resolveAliases(parser, i.left, aliases);
                try self.resolveAliases(parser, i.index, aliases);
            },
            .return_stmt => |r| if (r.value) |v| try self.resolveAliases(parser, v, aliases),
            .property_access_expr => |p| {
                try self.resolveAliases(parser, p.object, aliases);
                const obj_node = parser.tree.getNode(p.object);
                if (obj_node == .identifier) {
                    const obj_name_str = self.pool.get(obj_node.identifier.name_id);
                    if (aliases.get(obj_name_str)) |canon| {
                        const prop_name_str = self.pool.get(p.property_name_id);
                        const new_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ canon, prop_name_str });

                        const new_id = try self.pool.intern(self.allocator, new_name);
                        const node_ptr = &parser.tree.nodes.items[idx];
                        node_ptr.* = .{ .identifier = .{ ._type = .{ ._type = .identifier_token, .value = new_name, .line = 0, .column = 0 }, .name_id = new_id } };
                    }
                }
            },
            else => {},
        }
    }

    fn walkAndPrefix(self: *Linker, parser: *Parser, idx: NodeIndex, locals: *std.StringHashMap(void), alias: []const u8) anyerror!void {
        const node = parser.tree.getNode(idx);
        switch (node) {
            .function_decl => |f| for (f.body) |s| try self.walkAndPrefix(parser, s, locals, alias),
            .if_stmt => |i| {
                try self.walkAndPrefix(parser, i.condition, locals, alias);
                for (i.then_branch) |s| try self.walkAndPrefix(parser, s, locals, alias);
                if (i.else_branch) |eb| for (eb) |s| try self.walkAndPrefix(parser, s, locals, alias);
            },
            .for_stmt => |f| {
                try self.walkAndPrefix(parser, f.iterable, locals, alias);
                for (f.body) |s| try self.walkAndPrefix(parser, s, locals, alias);
            },
            .var_decl => |v| try self.walkAndPrefix(parser, v.value, locals, alias),
            .binary_expr => |b| {
                try self.walkAndPrefix(parser, b.left, locals, alias);
                try self.walkAndPrefix(parser, b.right, locals, alias);
            },
            .unary_expr => |u| try self.walkAndPrefix(parser, u.right, locals, alias),
            .pipeline_expr => |p| {
                try self.walkAndPrefix(parser, p.left, locals, alias);
                try self.walkAndPrefix(parser, p.right_call, locals, alias);
            },
            .call_expr => |c| {
                const callee_node = parser.tree.getNode(c.callee);
                if (callee_node == .identifier) {
                    const name_str = self.pool.get(callee_node.identifier.name_id);
                    if (locals.contains(name_str)) {
                        var node_ptr = &parser.tree.nodes.items[c.callee];
                        const new_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ alias, name_str });
                        node_ptr.identifier.name_id = try self.pool.intern(self.allocator, new_name);
                    }
                } else try self.walkAndPrefix(parser, c.callee, locals, alias);
                for (c.arguments) |arg| try self.walkAndPrefix(parser, arg, locals, alias);
            },
            .catch_expr => |c| {
                try self.walkAndPrefix(parser, c.expression, locals, alias);
                for (c.body) |s| try self.walkAndPrefix(parser, s, locals, alias);
            },
            .array_expr => |a| for (a.elements) |e| try self.walkAndPrefix(parser, e, locals, alias),
            .dict_expr => |d| for (d.entries) |e| {
                try self.walkAndPrefix(parser, e.key, locals, alias);
                try self.walkAndPrefix(parser, e.value, locals, alias);
            },
            .index_expr => |i| {
                try self.walkAndPrefix(parser, i.left, locals, alias);
                try self.walkAndPrefix(parser, i.index, locals, alias);
            },
            .return_stmt => |r| if (r.value) |v| try self.walkAndPrefix(parser, v, locals, alias),
            .property_access_expr => |p| try self.walkAndPrefix(parser, p.object, locals, alias),
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

        var global_tree = AstTree.init();
        defer global_tree.deinit(alloc);

        var pool = StringPool.init(alloc);
        defer pool.deinit(alloc);

        var result = runCompilerPipeline(alloc, &global_tree, &pool, file_path, io) catch return;
        defer alloc.free(result.source);
        defer result.parser.deinit();
        defer alloc.free(result.tokens);
        try io.stdout.print("Parser finished. AST generated successfully.\n", .{});
        return;
    }

    if (checker.strEquals(cmd, "run")) {
        const file = try getFlFile(&args, io);
        try runner(alloc, &args, file, io, true);
        return;
    }
    if (checker.strEquals(cmd, "build")) {
        const file = try getFlFile(&args, io);
        try runner(alloc, &args, file, io, false);
        return;
    }
    try help(io);
}

fn getFlFile(args: *std.process.ArgIterator, io: anytype) ![]const u8 {
    const file_path = args.next() orelse {
        try io.stderr.print("error: Provide .fl file\n", .{});
        return "";
    };
    return file_path;
}

fn runner(alloc: std.mem.Allocator, args: *std.process.ArgIterator, file_path: []const u8, io: anytype, is_run: bool) !void {
    var global_tree = AstTree.init();
    defer global_tree.deinit(alloc);

    var pool = StringPool.init(alloc);
    defer pool.deinit(alloc);

    var linker = Linker.init(alloc, &global_tree, &pool, io);
    defer linker.deinit();

    linker.linkFile(file_path, null) catch {};
    if (linker.has_error) return;

    const merged_root_idx = try global_tree.addNode(alloc, .{ .program = .{ .statements = linker.statements.items } });

    const exe_name = std.fs.path.stem(file_path);
    const system_rt_o = "/usr/share/flint/flint_rt.o";
    const system_rt_h = "/usr/share/flint/flint_rt.h";

    const precompiled = blk: {
        std.fs.cwd().access(system_rt_o, .{}) catch break :blk false;
        std.fs.cwd().access(system_rt_h, .{}) catch break :blk false;
        break :blk true;
    };
    const rt_path: []const u8 = if (precompiled) system_rt_o else "flint_rt.c";

    if (!precompiled) {
        var h_f = try std.fs.cwd().createFile("flint_rt.h", .{});
        try h_f.writeAll(flint_rt_h_content);
        h_f.close();
        var c_f = try std.fs.cwd().createFile("flint_rt.c", .{});
        try c_f.writeAll(flint_rt_c_content);
        c_f.close();
    }

    defer {
        if (!precompiled) {
            std.fs.cwd().deleteFile("flint_rt.h") catch {};
            std.fs.cwd().deleteFile("flint_rt.c") catch {};
        }
    }

    if (is_run) {
        var c_code_buffer = std.ArrayList(u8).empty;
        defer c_code_buffer.deinit(alloc);

        var emitter = CEmitter.init(alloc, &global_tree, &pool, file_path, true);
        try emitter.generate(c_code_buffer.writer(alloc), merged_root_idx);
        try c_code_buffer.append(alloc, 0);

        const tcc_state = tcc.tcc_new();
        if (tcc_state == null) {
            try io.stderr.print("Fatal: Failed to initialize libtcc.\n", .{});
            return;
        }
        defer tcc.tcc_delete(tcc_state);

        _ = tcc.tcc_set_output_type(tcc_state, tcc.TCC_OUTPUT_MEMORY);

        _ = tcc.tcc_add_include_path(tcc_state, ".");
        if (precompiled) {
            _ = tcc.tcc_add_include_path(tcc_state, "/usr/share/flint");
        }

        _ = tcc.tcc_add_library_path(tcc_state, "/usr/lib/x86_64-linux-gnu");
        _ = tcc.tcc_add_library_path(tcc_state, "/usr/lib");
        _ = tcc.tcc_add_library_path(tcc_state, "/usr/local/lib");

        if (tcc.tcc_add_library(tcc_state, "curl") == -1) {
            try io.stderr.print("JIT Warning: Could not explicitly link libcurl. HTTP module might fail.\n", .{});
        }

        const rt_path_z = try alloc.dupeZ(u8, rt_path);
        defer alloc.free(rt_path_z);
        if (tcc.tcc_add_file(tcc_state, rt_path_z) == -1) {
            try io.stderr.print("Fatal: Could not load flint runtime object.\n", .{});
            return;
        }

        if (tcc.tcc_compile_string(tcc_state, c_code_buffer.items.ptr) == -1) {
            try io.stderr.print("AOT (with tcc) Compilation Failed.\n", .{});

            std.debug.print("\n--- C CODE DUMP ---\n{s}\n", .{c_code_buffer.items});

            return;
        }

        if (tcc.tcc_relocate(tcc_state, tcc.TCC_RELOCATE_AUTO) < 0) {
            try io.stderr.print("JIT Relocation Failed.\n", .{});
            return;
        }

        const main_sym = tcc.tcc_get_symbol(tcc_state, "main");
        if (main_sym == null) {
            try io.stderr.print("JIT Error: main() not found.\n", .{});
            return;
        }

        const MainFn = *const fn (c_int, [*c][*c]u8) callconv(.c) c_int;
        const main_func: MainFn = @ptrCast(main_sym);

        var run_args = std.ArrayList([*c]u8).empty;
        defer run_args.deinit(alloc);

        const exe_name_z = try alloc.dupeZ(u8, exe_name);
        defer alloc.free(exe_name_z);
        try run_args.append(alloc, exe_name_z);

        while (args.next()) |a| {
            try run_args.append(alloc, try alloc.dupeZ(u8, a));
        }
        try run_args.append(alloc, null);

        const ret = main_func(@intCast(run_args.items.len - 1), run_args.items.ptr);

        if (ret != 0) {
            std.process.exit(@intCast(ret));
        }
        return;
    }

    try io.stdout.print("\x1b[38;5;208m[FLINT]\x1b[0m Transpiling and compiling native binary...\n", .{});
    _ = try io.stdout.flush();

    const system_rt_pch = "/usr/share/flint/flint_rt.h.pch";
    const has_pch = blk: {
        std.fs.cwd().access(system_rt_pch, .{}) catch break :blk false;
        break :blk true;
    };

    const compiler = getBestCCompiler(alloc, false);

    const c_args = try compiler.getArgsExtended(alloc, exe_name, rt_path, precompiled, false, has_pch);
    defer alloc.free(c_args);

    var child = std.process.Child.init(c_args, alloc);
    child.stdin_behavior = .Pipe;

    try child.spawn();
    {
        var buf: [4096]u8 = undefined;
        var writer = child.stdin.?.writer(&buf);
        var emitter = CEmitter.init(alloc, &global_tree, &pool, file_path, false);
        try emitter.generate(&writer.interface, merged_root_idx);
        try writer.interface.flush();
    }

    child.stdin.?.close();
    child.stdin = null;

    const term = try child.wait();
    if (term != .Exited or term.Exited != 0) return;

    try io.stdout.print("\x1b[1;32m[SUCCESS]\x1b[0m Executable '{s}' generated.\n", .{exe_name});
    _ = io.stdout.flush() catch {};
}

const TestResult = struct {
    file_path: []const u8,
    passed: bool,
};

const ActiveJob = struct {
    child: std.process.Child,
    file_path: []const u8,
};

pub fn runTests(alloc: std.mem.Allocator, io: IoHelper) !void {
    try io.stdout.print("\x1b[36m=== FLINT TEST BATTERY ===\x1b[0m\n\n", .{});
    var test_dir = try std.fs.cwd().openDir("tests", .{ .iterate = true });
    defer test_dir.close();
    var walker = try test_dir.walk(alloc);
    defer walker.deinit();

    var test_files = std.ArrayList([]const u8).empty;
    defer {
        for (test_files.items) |f| alloc.free(f);
        test_files.deinit(alloc);
    }

    while (try walker.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.basename, ".fl")) {
            const full_path = try std.fmt.allocPrint(alloc, "tests/{s}", .{entry.path});
            try test_files.append(alloc, full_path);
        }
    }

    const total_tests = test_files.items.len;
    var results = std.ArrayList(TestResult).empty;
    defer results.deinit(alloc);

    const flint_exe = try std.fs.selfExePathAlloc(alloc);
    defer alloc.free(flint_exe);

    const cpu_count = std.Thread.getCpuCount() catch 4;
    var active_jobs = std.ArrayList(ActiveJob).empty;
    defer active_jobs.deinit(alloc);

    var file_index: usize = 0;

    while (file_index < total_tests or active_jobs.items.len > 0) {
        while (active_jobs.items.len < cpu_count and file_index < total_tests) {
            const current_file = test_files.items[file_index];
            const argv = &[_][]const u8{ flint_exe, "run", current_file };

            var child = std.process.Child.init(argv, alloc);
            child.stdout_behavior = .Ignore;
            child.stderr_behavior = .Ignore;

            try child.spawn();
            try active_jobs.append(alloc, .{ .child = child, .file_path = current_file });
            file_index += 1;
        }

        if (active_jobs.items.len > 0) {
            var job = active_jobs.orderedRemove(0);
            const term = try job.child.wait();
            const passed = (term == .Exited and term.Exited == 0);

            try results.append(alloc, .{ .file_path = job.file_path, .passed = passed });

            if (passed) {
                try io.stdout.print("\x1b[32m[PASS]\x1b[0m {s}\n", .{job.file_path});
            } else {
                try io.stdout.print("\x1b[31m[FAIL]\x1b[0m {s}\n", .{job.file_path});
            }
        }
    }

    var pass_count: usize = 0;
    for (results.items) |res| {
        if (res.passed) pass_count += 1;
    }

    try io.stdout.print("\nTotal: {d} | \x1b[32mPassed: {d}\x1b[0m | \x1b[31mFailed: {d}\x1b[0m\n", .{ total_tests, pass_count, total_tests - pass_count });
}

const ClangCompiler = struct {
    pub fn getArgsExtended(self: ClangCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool) ![]const []const u8 {
        _ = self;
        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "clang");
        try args.append(alloc, rt);
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");

        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        if (is_run) {
            try args.append(alloc, "-O0");
        } else {
            try args.append(alloc, "-O3");
            try args.append(alloc, "-march=native");
        }

        try args.append(alloc, "-Wno-unused-value");

        if (has_pch and is_run) {
            try args.append(alloc, "-include-pch");
            try args.append(alloc, if (pre) "/usr/share/flint/flint_rt.h.pch" else "flint_rt.h.pch");
        }

        try args.append(alloc, "-lcurl");

        return args.toOwnedSlice(alloc);
    }
};

const GccCompiler = struct {
    pub fn getArgsExtended(self: GccCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool) ![]const []const u8 {
        _ = self;
        _ = has_pch;
        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "gcc");
        try args.append(alloc, rt);
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");

        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        if (is_run) {
            try args.append(alloc, "-O0");
        } else {
            try args.append(alloc, "-O3");
            try args.append(alloc, "-march=native");
        }

        try args.append(alloc, "-Wno-unused-value");
        try args.append(alloc, "-lcurl");

        return args.toOwnedSlice(alloc);
    }
};

const TccCompiler = struct {
    pub fn getArgsExtended(self: TccCompiler, alloc: std.mem.Allocator, out_exe: []const u8, pre: bool) ![]const []const u8 {
        _ = self;

        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "tcc");
        try args.append(alloc, if (pre) "/usr/share/flint/flint_rt.c" else "flint_rt.c");
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");

        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        try args.append(alloc, "-lcurl");

        return args.toOwnedSlice(alloc);
    }
};

pub const Compiler = union(enum) {
    clang: ClangCompiler,
    gcc: GccCompiler,
    tcc: TccCompiler,

    pub fn getArgsExtended(self: Compiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool) ![]const []const u8 {
        return switch (self) {
            .tcc => |t| t.getArgsExtended(alloc, out_exe, pre),
            .clang => |c| c.getArgsExtended(alloc, out_exe, rt, pre, is_run, has_pch),
            .gcc => |g| g.getArgsExtended(alloc, out_exe, rt, pre, is_run, has_pch),
        };
    }
};

fn getBestCCompiler(alloc: std.mem.Allocator, is_run: bool) Compiler {
    if (cached_compiler) |c| return c;

    if (is_run) {
        if (isCompilerPresent(alloc, "tcc")) {
            const r = Compiler{
                .tcc = TccCompiler{},
            };

            cached_compiler = r;
            return r;
        }
    }

    const result: Compiler = blk: {
        if (isCompilerPresent(alloc, "clang")) break :blk .{ .clang = ClangCompiler{} };
        if (isCompilerPresent(alloc, "gcc")) break :blk .{ .gcc = GccCompiler{} };
        if (isCompilerPresent(alloc, "tcc")) break :blk .{ .tcc = TccCompiler{} };
        break :blk .{ .clang = ClangCompiler{} };
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
        if (std.posix.access(full, std.posix.X_OK)) |_| return true else |_| continue;
    }
    return false;
}

const ok = void{};
