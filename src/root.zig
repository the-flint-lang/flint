const std = @import("std");
const builtin = @import("builtin");

const tcc = @cImport({
    @cInclude("libtcc.h");
});

const cl = @cImport({
    @cInclude("stdlib.h");
});

const checker = @import("./core/helpers/utils/checkers.zig");
pub const IoHelper = @import("./core/helpers/structs/structs.zig").IoHelpers;
const Lexer = @import("./core/lexer/lexer.zig").Lexer;
const Parser = @import("./core/parser/parser.zig").Parser;
const TypeChecker = @import("./core/analyzer/type_checker.zig").TypeChecker;
const SourceManager = @import("./core/helpers/utils/source_manager.zig").SourceManager;
const ast = @import("./core/parser/ast.zig");
const NodeIndex = ast.NodeIndex;
const AstTree = ast.AstTree;
const StringPool = ast.StringPool;
const CEmitter = @import("./core/codegen/c_emitter.zig").CEmitter;
const AstNode = ast.AstNode;
const Token = @import("./core/lexer/structs/token.zig").Token;
const help = @import("./core/helpers/functions/help.zig");
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

fn runCompilerPipeline(
    alloc: std.mem.Allocator,
    tree: *AstTree,
    pool: *StringPool,
    source_mgr: *SourceManager,
    file_path: []const u8,
    io: IoHelper,
) !PipelineResult {
    if (!std.mem.endsWith(u8, file_path, ".fl")) {
        return error.InvalidFileType;
    }

    const source = try std.Io.Dir.cwd().readFileAlloc(io.sys.io, file_path, alloc, std.Io.Limit.limited(1024 * 1024));
    const file_id = try source_mgr.addFile(file_path, source);

    var lex = Lexer{
        .alloc = alloc,
        .io = io,
        .file_path = file_path,
        .file_id = file_id,
        .position = 0,
        .column = 0,
        .line = 0,
        .tokens = .empty,
        .source = source,
    };
    const tokens = try lex.tokenize();

    var parser = Parser.init(alloc, tree, pool, tokens, source, file_path, file_id, io);
    const root_idx = try parser.parse();

    if (parser.had_error) {
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
    source_mgr: *SourceManager,
    io: IoHelper,
    has_error: bool = false,
    flags: *FlintFlags,

    pub fn init(alloc: std.mem.Allocator, tree: *AstTree, pool: *StringPool, source_mgr: *SourceManager, io: IoHelper, flags: *FlintFlags) Linker {
        return .{
            .allocator = alloc,
            .tree = tree,
            .pool = pool,
            .source_mgr = source_mgr,
            .visited = std.StringHashMap(void).init(alloc),
            .statements = std.ArrayList(NodeIndex).empty,
            .results = std.ArrayList(*PipelineResult).empty,
            .io = io,
            .flags = flags,
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
        var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
        const abs_len = std.Io.Dir.cwd().realPathFile(self.io.sys.io, file_path, &abs_buf) catch {
            try self.io.stderr.print("Fatal Error: Unable to import file '{s}'.\n", .{file_path});
            self.has_error = true;
            return;
        };
        const abs_path = try self.allocator.dupe(u8, abs_buf[0..abs_len]);
        defer self.allocator.free(abs_path);

        if (self.visited.contains(abs_path)) return;
        try self.visited.put(try self.allocator.dupe(u8, abs_path), {});

        const result_ptr = try self.allocator.create(PipelineResult);
        result_ptr.* = runCompilerPipeline(self.allocator, self.tree, self.pool, self.source_mgr, file_path, self.io) catch {
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

                if (checker.strEquals(import_raw, "http")) {
                    self.flags.uses_http = true;
                }
                const next_alias_str = if (next_alias_id) |id| self.pool.get(id) else null;

                const basename = std.fs.path.basename(import_raw);
                const canon_name = basename[0 .. std.mem.indexOf(u8, basename, ".") orelse basename.len];

                const formatted_path = if (!std.mem.endsWith(u8, import_raw, ".fl"))
                    try std.fmt.allocPrint(self.allocator, "std/{s}.fl", .{import_raw})
                else
                    try self.allocator.dupe(u8, import_raw);

                const next_file = if (std.mem.startsWith(u8, formatted_path, "./") or std.mem.startsWith(u8, formatted_path, "../"))
                    try std.fs.path.join(self.allocator, &.{ base_dir, formatted_path })
                else blk: {
                    var std_base: []const u8 = "/usr/share/flint";
                    const env_ptr = cl.getenv("FLINT_LIB_PATH");

                    if (env_ptr != null) {
                        std_base = std.mem.span(env_ptr);
                    } else {
                        if (std.Io.Dir.cwd().openDir(self.io.sys.io, "std", .{})) |d| {
                            self.io.sys.io.vtable.dirClose(self.io.sys.io.userdata, &.{d});
                            std_base = ".";
                        } else |_| {}
                    }
                    break :blk try std.fs.path.join(self.allocator, &.{ std_base, formatted_path });
                };

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

                        const original_line = p.line;
                        const original_col = obj_node.identifier.token.column;

                        node_ptr.* = .{ .identifier = .{ .token = .{
                            ._type = .identifier_token,
                            .value = new_name,
                            .line = original_line,
                            .column = original_col,
                            .file_id = obj_node.identifier.token.file_id,
                        }, .name_id = new_id } };
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

const CpuArchs = enum {
    x86_64,
    aarch,
    baseline, // fallback
};

const Compilers = enum {
    tcc,
    clang,
    gcc,
    zigcc,
    musl,
};

const FlintFlags = struct {
    is_less_mode: bool,
    is_static: bool,
    is_test: bool,
    cpu_arch: CpuArchs,
    is_release: bool = false,
    compiler_forced: bool = false,
    compiler: Compilers,
    uses_http: bool,

    arena_size: u64 = 4 * 1024 * 1024 * 1024, // 4GB
    persist_size: u64 = 1 * 1024 * 1024 * 1024, // 1GB

    output_name: []const u8 = "",

    fn getDefaultArch(_: FlintFlags) CpuArchs {
        const arch = builtin.cpu.arch;
        if (arch == .x86_64) {
            return .x86_64;
        } else if (builtin.cpu.arch == .aarch64) {
            return .aarch;
        } else {
            return .baseline;
        }
    }
};

pub fn runCli(alloc: std.mem.Allocator, io: IoHelper, args: []const []const u8) !void {
    var command: ?[]const u8 = null;
    var file_path: ?[]const u8 = null;
    var script_args_start: usize = args.len;

    var flags = FlintFlags{
        .is_less_mode = false,
        .is_static = false,
        .is_test = false,
        .cpu_arch = .baseline,
        .uses_http = false,
        .compiler = .clang,
    };
    flags.cpu_arch = flags.getDefaultArch();

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (command == null) {
            if (checker.cliArgsEquals(arg, &.{ "-h", "--help" })) {
                try help.help(io);
                return;
            }

            if (checker.cliArgsEquals(arg, &.{ "-V", "--version" })) {
                try version(io);
                return;
            }

            if (checker.cliArgsEquals(arg, &.{ "-t", "--test" })) {
                flags.is_test = true;
                continue;
            }

            command = arg;
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{ "-h", "--help" })) {
            if (checker.strEquals(command.?, "build")) {
                try help.helpBuild(io);
            } else if (checker.strEquals(command.?, "run")) {
                try help.helpRun(io);
            } else if (checker.strEquals(command.?, "test")) {
                try help.helpTest(io);
            } else {
                try help.help(io);
            }
            return;
        }

        if (file_path == null and !std.mem.startsWith(u8, arg, "-")) {
            file_path = arg;
            script_args_start = i + 1;
            break;
        }
    }

    const cmd = command orelse {
        try help.help(io);
        return;
    };

    if (checker.strEquals(cmd, "test")) {
        try runTests(alloc, io);
        return;
    }

    const file = file_path orelse {
        try io.stderr.print("error: Provide .fl file\n", .{});
        return;
    };

    const remaining_args = args[script_args_start..];

    if (checker.strEquals(cmd, "lex")) {
        const source = try std.Io.Dir.cwd().readFileAlloc(io.sys.io, file, alloc, std.Io.Limit.limited(1024 * 1024));
        defer alloc.free(source);

        var lexer = Lexer{
            .alloc = alloc,
            .io = io,
            .file_path = file,
            .position = 0,
            .file_id = 0,
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
        var global_tree = AstTree.init();
        defer global_tree.deinit(alloc);

        var pool = StringPool.init(alloc);
        defer pool.deinit(alloc);

        var source_manager = SourceManager.init(alloc);
        defer source_manager.deinit();

        var result = runCompilerPipeline(alloc, &global_tree, &pool, &source_manager, file, io) catch return;

        defer alloc.free(result.source);
        defer result.parser.deinit();
        defer alloc.free(result.tokens);
        try io.stdout.print("Parser finished. AST generated successfully.\n", .{});
        return;
    }

    if (checker.strEquals(cmd, "run")) {
        try runner(alloc, remaining_args, file, io, true, &flags);
        return;
    }

    if (checker.strEquals(cmd, "build")) {
        parseFlags(remaining_args, &flags, io) catch {
            return;
        };

        try runner(alloc, remaining_args, file, io, false, &flags);
        return;
    }

    try help.help(io);
}

pub fn parseFlags(args: []const []const u8, flags: *FlintFlags, io: IoHelper) !void {
    var i: usize = 0;

    while (i < args.len) : (i += 1) {
        const arg = args[i];

        if (checker.cliArgsEquals(arg, &.{ "-C", "--compiler" })) {
            i += 1;
            if (i >= args.len) return error.MissingCompiler;

            const comp_arg = args[i];
            if (checker.strEquals(comp_arg, "musl")) {
                flags.compiler = .musl;
            } else if (checker.strEquals(comp_arg, "zigcc")) {
                flags.compiler = .zigcc;
            } else if (checker.strEquals(comp_arg, "tcc")) {
                flags.compiler = .tcc;
            } else if (checker.strEquals(comp_arg, "clang")) {
                flags.compiler = .clang;
            } else if (checker.strEquals(comp_arg, "gcc")) {
                flags.compiler = .gcc;
            } else {
                try io.stderr.print("Invalid compiler. Use: zigcc, tcc, clang or gcc.\n", .{});
                return error.InvalidCompiler;
            }
            flags.compiler_forced = true;
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{"--release"})) {
            flags.is_release = true;
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{ "-s", "--small" })) {
            flags.is_less_mode = true;
            if (flags.arena_size == 4 * 1024 * 1024 * 1024) flags.arena_size = 16 * 1024 * 1024;
            if (flags.persist_size == 1 * 1024 * 1024 * 1024) flags.persist_size = 4 * 1024 * 1024;
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{ "-S", "--static" })) {
            flags.is_static = true;
            flags.is_less_mode = true;

            if (flags.arena_size == 4 * 1024 * 1024 * 1024) flags.arena_size = 16 * 1024 * 1024;
            if (flags.persist_size == 1 * 1024 * 1024 * 1024) flags.persist_size = 4 * 1024 * 1024;
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{ "-c", "--cpu" })) {
            i += 1;
            if (i >= args.len) return error.MissingCpuArch;

            const cpu_arg = args[i];
            if (checker.cliArgsEquals(cpu_arg, &.{"baseline"})) {
                flags.cpu_arch = .baseline;
            } else if (checker.cliArgsEquals(cpu_arg, &.{"x86_64"})) {
                flags.cpu_arch = .x86_64;
            } else if (checker.cliArgsEquals(cpu_arg, &.{"aarch"})) {
                flags.cpu_arch = .aarch;
            } else {
                return error.InvalidCpuArch;
            }
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{ "-o", "--output" })) {
            i += 1;
            if (i >= args.len) return error.MissingOutputName;
            flags.output_name = args[i];
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{"--arena-size"})) {
            i += 1;
            if (i >= args.len) return error.MissingArenaSize;
            flags.arena_size = try parseCapacityBytes(args[i]);
            continue;
        }

        if (checker.cliArgsEquals(arg, &.{"--persist-size"})) {
            i += 1;
            if (i >= args.len) return error.MissingPersistSize;
            flags.persist_size = try parseCapacityBytes(args[i]);
            continue;
        }

        try help.help(io);
        try io.stderr.print("Unknown command: '{s}'\n", .{arg});
        try io.stderr.flush();
        return error.unknownCommand;
    }
}

fn runner(alloc: std.mem.Allocator, args: []const []const u8, file_path: []const u8, io: anytype, is_run: bool, flags: *FlintFlags) !void {
    var global_tree = AstTree.init();
    defer global_tree.deinit(alloc);

    var pool = StringPool.init(alloc);
    defer pool.deinit(alloc);

    var source_manager = SourceManager.init(alloc);
    defer source_manager.deinit();

    var linker = Linker.init(alloc, &global_tree, &pool, &source_manager, io, flags);
    defer linker.deinit();

    linker.linkFile(file_path, null) catch {};
    if (linker.has_error) return error.LinkerFailed;

    const merged_root_idx = try global_tree.addNode(alloc, .{ .program = .{ .statements = linker.statements.items } });

    const main_source = try std.Io.Dir.cwd().readFileAlloc(io.sys.io, file_path, alloc, std.Io.Limit.limited(1024 * 1024));
    defer alloc.free(main_source);

    var final_checker = try TypeChecker.init(alloc, &global_tree, &pool, &source_manager, io);
    try final_checker.check(merged_root_idx);

    if (final_checker.had_error) {
        try io.stderr.print("Linkage/Semantic error across files.\n", .{});
        return error.err;
    }

    var exe_name_buf: [128]u8 = undefined;
    const exe_name = if (flags.output_name.len > 0)
        flags.output_name
    else if (flags.is_test) blk: {
        const hash = std.hash.Fnv1a_64.hash(file_path);
        break :blk std.fmt.bufPrint(&exe_name_buf, ".test_bin_{x}", .{hash}) catch "test_bin";
    } else std.fs.path.stem(file_path);

    const system_rt_h = "/usr/share/flint/flint_rt.h";

    const rt_base_o = "/usr/share/flint/flint_rt.o";
    const rt_http_o = "/usr/share/flint/flint_rt_http.o";

    const precompiled = blk: {
        if (flags.cpu_arch != flags.getDefaultArch()) break :blk false;

        std.Io.Dir.cwd().access(io.sys.io, rt_base_o, .{}) catch break :blk false;
        std.Io.Dir.cwd().access(io.sys.io, rt_http_o, .{}) catch break :blk false;
        std.Io.Dir.cwd().access(io.sys.io, system_rt_h, .{}) catch break :blk false;
        break :blk true;
    };

    const rt_path: []const u8 = if (precompiled)
        (if (flags.uses_http) rt_http_o else rt_base_o)
    else
        "flint_rt.c";

    if (!precompiled) {
        const h_f = try std.Io.Dir.cwd().createFile(io.sys.io, "flint_rt.h", .{});
        try std.Io.File.writeStreamingAll(h_f, io.sys.io, flint_rt_h_content);
        io.sys.io.vtable.fileClose(io.sys.io.userdata, &.{h_f});

        const c_f = try std.Io.Dir.cwd().createFile(io.sys.io, "flint_rt.c", .{});
        try std.Io.File.writeStreamingAll(c_f, io.sys.io, flint_rt_c_content);
        io.sys.io.vtable.fileClose(io.sys.io.userdata, &.{c_f});
    }

    defer {
        if (!precompiled) {
            std.Io.Dir.cwd().deleteFile(io.sys.io, "flint_rt.h") catch {};
            std.Io.Dir.cwd().deleteFile(io.sys.io, "flint_rt.c") catch {};
        }
        if (flags.is_test) {
            std.Io.Dir.cwd().deleteFile(io.sys.io, exe_name) catch {};
        }
    }

    if (is_run) {
        var c_code_buffer = std.Io.Writer.Allocating.init(alloc);
        defer c_code_buffer.deinit();

        var emitter = CEmitter.init(alloc, &global_tree, &pool, final_checker.node_types, file_path, true, io.sys.io);

        try emitter.generate(&c_code_buffer.writer, merged_root_idx);

        try c_code_buffer.writer.writeByte(0);

        const c_code_items = c_code_buffer.written();

        var jit_success = false;

        const tcc_state = tcc.tcc_new();
        if (tcc_state != null) {
            tcc.tcc_set_error_func(tcc_state, null, silentErrorCallback);
            defer tcc.tcc_delete(tcc_state);

            _ = tcc.tcc_set_output_type(tcc_state, tcc.TCC_OUTPUT_MEMORY);
            _ = tcc.tcc_add_include_path(tcc_state, ".");
            if (precompiled) _ = tcc.tcc_add_include_path(tcc_state, "/usr/share/flint");

            _ = tcc.tcc_add_library_path(tcc_state, "/usr/lib/x86_64-linux-gnu");
            _ = tcc.tcc_add_library_path(tcc_state, "/usr/lib");
            _ = tcc.tcc_add_library_path(tcc_state, "/usr/local/lib");

            if (flags.uses_http) {
                if (tcc.tcc_add_library(tcc_state, "curl") == -1) {
                    try io.stderr.print("JIT Warning: Could not explicitly link libcurl.\n", .{});
                }
            } else {
                tcc.tcc_define_symbol(tcc_state, "FLINT_NO_HTTP", "1");
            }

            const rt_path_z = try alloc.dupeZ(u8, rt_path);
            defer alloc.free(rt_path_z);

            if (tcc.tcc_add_file(tcc_state, rt_path_z) != -1 and
                tcc.tcc_compile_string(tcc_state, c_code_items.ptr) != -1 and
                tcc.tcc_relocate(tcc_state, tcc.TCC_RELOCATE_AUTO) >= 0)
            {
                const main_sym = tcc.tcc_get_symbol(tcc_state, "main");
                if (main_sym != null) {
                    jit_success = true;
                    const MainFn = *const fn (c_int, [*c][*c]u8) callconv(.c) c_int;
                    const main_func: MainFn = @ptrCast(@alignCast(main_sym));

                    var run_args = std.ArrayList([*c]u8).empty;
                    defer run_args.deinit(alloc);

                    const exe_name_z = try alloc.dupeZ(u8, exe_name);
                    defer alloc.free(exe_name_z);
                    try run_args.append(alloc, exe_name_z);

                    for (args) |a| try run_args.append(alloc, try alloc.dupeZ(u8, a));
                    try run_args.append(alloc, null);

                    const ret = main_func(@intCast(run_args.items.len - 1), run_args.items.ptr);
                    if (ret != 0) std.process.exit(@intCast(ret));
                    return;
                }
            }
        }

        if (!jit_success) {
            try io.stderr.print("\x1b[33m[COMPILATION FALLBACK]\x1b[0m TCC limit reached. Deferring to Clang/GCC/Musl/Zig pipeline...\n\n", .{});
            _ = io.stderr.flush() catch {};

            const tmp_exe = try std.fmt.allocPrint(alloc, ".{s}_tmp_run", .{exe_name});
            defer alloc.free(tmp_exe);

            var compiled = false;
            const compilers = [_][]const u8{ "clang", "gcc", "zig cc", "musl-gcc" };

            for (compilers) |comp_name| {
                if (!isCompilerPresent(alloc, io.sys.io, comp_name)) continue;

                var cmd = std.ArrayList([]const u8).empty;
                defer cmd.deinit(alloc);

                try cmd.append(alloc, comp_name);
                try cmd.append(alloc, rt_path);
                try cmd.append(alloc, "-x");
                try cmd.append(alloc, "c");
                try cmd.append(alloc, "-");
                try cmd.append(alloc, "-o");
                try cmd.append(alloc, tmp_exe);
                try cmd.append(alloc, "-I.");
                if (precompiled) try cmd.append(alloc, "-I/usr/share/flint");

                try cmd.append(alloc, "-O0");
                if (flags.uses_http) {
                    try cmd.append(alloc, "-lcurl");
                } else {
                    try cmd.append(alloc, "-DFLINT_NO_HTTP");
                }
                try cmd.append(alloc, "-Wno-unused-value");

                var child = try io.sys.io.vtable.processSpawn(io.sys.io.userdata, .{
                    .argv = cmd.items,
                    .stdin = .pipe,
                    .stderr = .ignore,
                });

                const stdin_file = child.stdin.?;
                var stdin_buf: [4096]u8 = undefined;
                var file_writer = std.Io.File.Writer.init(stdin_file, io.sys.io, &stdin_buf);
                try file_writer.interface.writeAll(c_code_items);
                try file_writer.interface.flush();

                io.sys.io.vtable.fileClose(io.sys.io.userdata, &.{stdin_file});
                child.stdin = null;

                const term = try io.sys.io.vtable.childWait(io.sys.io.userdata, &child);
                if (term == .exited and term.exited == 0) {
                    compiled = true;
                    break;
                }
            }

            if (!compiled) {
                try io.stderr.print("\x1b[1;31m[FATAL ERROR]\x1b[0m All backend compilers (TCC, Clang, GCC, Zig cc, Musl-gcc) failed. Syntax tree is heavily broken.\n", .{});
                return error.FallbackCompilationFailed;
            }

            var run_cmd = std.ArrayList([]const u8).empty;
            defer run_cmd.deinit(alloc);

            const local_tmp_exe = try std.fmt.allocPrint(alloc, "./{s}", .{tmp_exe});
            defer alloc.free(local_tmp_exe);
            try run_cmd.append(alloc, local_tmp_exe);

            for (args) |a| try run_cmd.append(alloc, a);

            var run_child = try io.sys.io.vtable.processSpawn(io.sys.io.userdata, .{
                .argv = run_cmd.items,
            });

            const term = try io.sys.io.vtable.childWait(io.sys.io.userdata, &run_child);

            std.Io.Dir.cwd().deleteFile(io.sys.io, tmp_exe) catch {};

            switch (term) {
                .exited => |code| {
                    if (code != 0) std.process.exit(code);
                },
                .signal => |sig| {
                    try io.stderr.print("\x1b[1;31m[RUNTIME CRASH]\x1b[0m Native binary died with signal {d} (Segfault/Abort).\n", .{sig});
                    std.process.exit(1);
                },
                else => std.process.exit(1),
            }
            return;
        }
    }

    if (flags.compiler_forced and flags.compiler == .musl and flags.uses_http) {
        try io.stderr.print("\x1b[1;31m[FATAL ERROR]\x1b[0m The 'musl-gcc' compiler does not support the 'http' module natively on Linux (requires static libcurl for musl).\nRemove the '-C musl' flag to use automatic fallback (GCC/Clang).\n", .{});
        return error.IncompatibleCompiler;
    }

    try io.stdout.print("\x1b[38;5;208m[FLINT]\x1b[0m Transpiling and compiling native binary...\n", .{});
    _ = try io.stdout.flush();

    const system_rt_pch = "/usr/share/flint/flint_rt.h.pch";
    const has_pch = blk: {
        std.Io.Dir.cwd().access(io.sys.io, system_rt_pch, .{}) catch break :blk false;
        break :blk true;
    };

    const compiler = getBestCCompiler(alloc, false, io.sys.io, flags);

    const c_args = try compiler.getArgsExtended(alloc, exe_name, rt_path, precompiled, false, has_pch, flags);
    defer alloc.free(c_args);

    var child = try io.sys.io.vtable.processSpawn(io.sys.io.userdata, .{
        .argv = c_args,
        .stdin = .pipe,
    });
    {
        var buf: [4096]u8 = undefined;
        const stdin_file = child.stdin.?;
        var file_writer = std.Io.File.Writer.init(stdin_file, io.sys.io, &buf);

        var emitter = CEmitter.init(alloc, &global_tree, &pool, final_checker.node_types, file_path, false, io.sys.io);
        try emitter.generate(&file_writer.interface, merged_root_idx);
        try file_writer.interface.flush();
    }

    io.sys.io.vtable.fileClose(io.sys.io.userdata, &.{child.stdin.?});
    child.stdin = null;

    const term = try io.sys.io.vtable.childWait(io.sys.io.userdata, &child);

    if (term != .exited or term.exited != 0) return;

    try io.stdout.print("\x1b[1;32m[SUCCESS]\x1b[0m Executable '{s}' generated.\n", .{exe_name});
    _ = io.stdout.flush() catch {};
}

fn silentErrorCallback(user_data: ?*anyopaque, msg: [*c]const u8) callconv(.c) void {
    _ = user_data;
    _ = msg;
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

    const cwd = std.Io.Dir.cwd();
    var test_dir = try cwd.openDir(io.sys.io, "tests", .{ .iterate = true });

    var walker = try test_dir.walk(alloc);
    defer walker.deinit();

    var test_files = std.ArrayList([]const u8).empty;
    defer {
        for (test_files.items) |f|
            alloc.free(f);

        test_files.deinit(alloc);
    }

    while (try walker.next(io.sys.io)) |entry| {
        if (entry.kind == .file and
            std.mem.endsWith(u8, entry.basename, ".fl"))
        {
            const full_path =
                try std.fmt.allocPrint(alloc, "tests/{s}", .{entry.path});

            try test_files.append(alloc, full_path);
        }
    }

    io.sys.io.vtable.dirClose(io.sys.io.userdata, &.{test_dir});

    const total_tests = test_files.items.len;

    var results = std.ArrayList(TestResult).empty;
    defer results.deinit(alloc);

    var exe_buf: [std.fs.max_path_bytes]u8 = undefined;
    const exe_len = try io.sys.io.vtable.processExecutablePath(io.sys.io.userdata, &exe_buf);
    const flint_exe = try alloc.dupe(u8, exe_buf[0..exe_len]);
    defer alloc.free(flint_exe);

    const cpu_count = std.Thread.getCpuCount() catch 4;

    var active_jobs = std.ArrayList(ActiveJob).empty;
    defer active_jobs.deinit(alloc);

    var file_index: usize = 0;

    while (file_index < total_tests or active_jobs.items.len > 0) {
        while (active_jobs.items.len < cpu_count and
            file_index < total_tests)
        {
            const current_file = test_files.items[file_index];

            const argv =
                &[_][]const u8{ flint_exe, "run", current_file, "-t" };

            const child = try io.sys.io.vtable.processSpawn(io.sys.io.userdata, .{
                .argv = argv,
                .stdin = .pipe,
                .stdout = .ignore,
                .stderr = .ignore,
            });

            try active_jobs.append(
                alloc,
                .{
                    .child = child,
                    .file_path = current_file,
                },
            );

            file_index += 1;
        }

        if (active_jobs.items.len > 0) {
            var job = active_jobs.orderedRemove(0);

            const term = try io.sys.io.vtable.childWait(io.sys.io.userdata, &job.child);

            const passed = switch (term) {
                .exited => |code| code == 0,
                else => false,
            };

            try results.append(
                alloc,
                .{
                    .file_path = job.file_path,
                    .passed = passed,
                },
            );

            if (passed) {
                try io.stdout.print(
                    "\x1b[32m[PASS]\x1b[0m {s}\n",
                    .{job.file_path},
                );
            } else {
                try io.stdout.print(
                    "\x1b[31m[FAIL]\x1b[0m {s}\n",
                    .{job.file_path},
                );
            }
        }
    }

    var pass_count: usize = 0;

    for (results.items) |res| {
        if (res.passed)
            pass_count += 1;
    }

    try io.stdout.print(
        "\nTotal: {d} | \x1b[32mPassed: {d}\x1b[0m | \x1b[31mFailed: {d}\x1b[0m\n",
        .{ total_tests, pass_count, total_tests - pass_count },
    );
}

const ClangCompiler = struct {
    pub fn getArgsExtended(self: ClangCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool, flags: *FlintFlags) ![]const []const u8 {
        _ = self;
        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "clang");
        try args.append(alloc, rt);
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");

        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        const arena_macro = try std.fmt.allocPrint(alloc, "-DARENA_CAPACITY={d}ULL", .{flags.arena_size});
        try args.append(alloc, arena_macro);

        const persist_macro = try std.fmt.allocPrint(alloc, "-DPERSISTENT_CAPACITY={d}ULL", .{flags.persist_size});
        try args.append(alloc, persist_macro);

        if (flags.is_static) {
            try args.append(alloc, "-static");
        }

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        if (is_run) {
            try args.append(alloc, "-O0");
        } else {
            try args.append(alloc, if (flags.is_less_mode) "-Oz" else if (flags.cpu_arch == .baseline) "-O2" else "-O3");
            try args.append(alloc, "-flto");
            try args.append(alloc, "-finline-functions");
            try args.append(alloc, "-ffunction-sections");
            try args.append(alloc, "-fdata-sections");
            try args.append(alloc, "-Wl,--gc-sections");
            try args.append(alloc, "-fno-stack-protector");
            try args.append(alloc, "-fno-unwind-tables");
            try args.append(alloc, "-fno-asynchronous-unwind-tables");
            try args.append(alloc, "-fno-ident");
            try args.append(alloc, "-Wl,--build-id=none");
            try args.append(alloc, "-fvisibility=hidden");
            try args.append(alloc, "-s");
            try args.append(alloc, "-fomit-frame-pointer");
            try args.append(alloc, "-fstrict-aliasing");
            try args.append(alloc, "-fno-semantic-interposition");
            try args.append(alloc, "-fno-plt");
            try args.append(alloc, "-fmerge-all-constants");

            try args.append(alloc, "-fno-exceptions");
            try args.append(alloc, "-fno-rtti");
            try args.append(alloc, "-pipe");
            try args.append(alloc, "-mllvm");
            try args.append(alloc, "-inline-threshold=500");

            switch (flags.cpu_arch) {
                .x86_64 => {
                    try args.append(alloc, "--target=x86_64-linux-gnu");
                    try args.append(alloc, "-march=x86-64");
                },
                .aarch => {
                    try args.append(alloc, "--target=aarch64-linux-gnu");
                    try args.append(alloc, "-mcpu=generic");
                },
                .baseline => {},
            }

            if (flags.is_release) {
                try args.append(alloc, if (flags.is_less_mode) "-Oz" else "-O3");
                try args.append(alloc, "-flto");
                try args.append(alloc, "-ffunction-sections");
                try args.append(alloc, "-fdata-sections");
                try args.append(alloc, "-Wl,--gc-sections");
                try args.append(alloc, "-fno-unwind-tables");
                try args.append(alloc, "-fno-asynchronous-unwind-tables");
                try args.append(alloc, "-fno-ident");
                try args.append(alloc, "-Wl,--build-id=none");
                try args.append(alloc, "-fno-stack-protector");
                try args.append(alloc, "-fvisibility=hidden");
                try args.append(alloc, "-s");
            } else {
                try args.append(alloc, if (flags.is_less_mode) "-Os" else "-O1");
            }
        }

        try args.append(alloc, "-Wno-unused-value");

        if (has_pch and is_run) {
            try args.append(alloc, "-include-pch");
            try args.append(alloc, if (pre) "/usr/share/flint/flint_rt.h.pch" else "flint_rt.h.pch");
        }

        if (!flags.uses_http) {
            try args.append(alloc, "-DFLINT_NO_HTTP");
        }

        if (flags.uses_http) {
            try args.append(alloc, "-lcurl");
        }

        return args.toOwnedSlice(alloc);
    }
};

const GccCompiler = struct {
    pub fn getArgsExtended(self: GccCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool, flags: *FlintFlags) ![]const []const u8 {
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

        const arena_macro = try std.fmt.allocPrint(alloc, "-DARENA_CAPACITY={d}ULL", .{flags.arena_size});
        try args.append(alloc, arena_macro);

        const persist_macro = try std.fmt.allocPrint(alloc, "-DPERSISTENT_CAPACITY={d}ULL", .{flags.persist_size});
        try args.append(alloc, persist_macro);

        if (flags.is_static) {
            try args.append(alloc, "-static");
            try args.append(alloc, "-static-libgcc");
        }

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);
        try args.append(alloc, if (flags.is_less_mode) "-Oz" else if (flags.cpu_arch == .baseline) "-O2" else "-O3");

        if (is_run) {
            try args.append(alloc, "-O0");
        } else {
            try args.append(alloc, "-flto");
            try args.append(alloc, "-mtune=native");
            try args.append(alloc, "-finline-functions");
            try args.append(alloc, "-ffunction-sections");
            try args.append(alloc, "-fdata-sections");
            try args.append(alloc, "-Wl,--gc-sections");
            try args.append(alloc, "-fno-stack-protector");
            try args.append(alloc, "-fno-unwind-tables");
            try args.append(alloc, "-fno-asynchronous-unwind-tables");
            try args.append(alloc, "-fno-ident");
            try args.append(alloc, "-Wl,--build-id=none");
            try args.append(alloc, "-fvisibility=hidden");
            try args.append(alloc, "-s");
            try args.append(alloc, "-fomit-frame-pointer");
            try args.append(alloc, "-fstrict-aliasing");
            try args.append(alloc, "-fno-semantic-interposition");
            try args.append(alloc, "-fno-plt");
            try args.append(alloc, "-fmerge-all-constants");
            try args.append(alloc, "-fwhole-program");

            if (flags.is_release) {
                try args.append(alloc, if (flags.is_less_mode) "-Oz" else "-O3");
                try args.append(alloc, "-flto");
                try args.append(alloc, "-ffunction-sections");
                try args.append(alloc, "-fdata-sections");
                try args.append(alloc, "-Wl,--gc-sections");
                try args.append(alloc, "-fno-unwind-tables");
                try args.append(alloc, "-fno-asynchronous-unwind-tables");
                try args.append(alloc, "-fno-ident");
                try args.append(alloc, "-Wl,--build-id=none");
                try args.append(alloc, "-fno-stack-protector");
                try args.append(alloc, "-fvisibility=hidden");
                try args.append(alloc, "-s");
            } else {
                try args.append(alloc, if (flags.is_less_mode) "-Os" else "-O1");
            }
        }

        if (!flags.uses_http) {
            try args.append(alloc, "-DFLINT_NO_HTTP");
        }

        try args.append(alloc, "-Wno-unused-value");

        return args.toOwnedSlice(alloc);
    }
};

const MuslCompiler = struct {
    pub fn getArgsExtended(self: MuslCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool, flags: *FlintFlags) ![]const []const u8 {
        _ = self;
        _ = has_pch;
        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "musl-gcc");
        try args.append(alloc, rt);
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");

        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        const arena_macro = try std.fmt.allocPrint(alloc, "-DARENA_CAPACITY={d}ULL", .{flags.arena_size});
        try args.append(alloc, arena_macro);

        const persist_macro = try std.fmt.allocPrint(alloc, "-DPERSISTENT_CAPACITY={d}ULL", .{flags.persist_size});
        try args.append(alloc, persist_macro);

        if (flags.is_static) {
            try args.append(alloc, "-static");
        }
        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        if (is_run) {
            try args.append(alloc, "-O0");
        } else {
            if (flags.is_release) {
                try args.append(alloc, if (flags.is_less_mode) "-Os" else "-O3");
                try args.append(alloc, "-flto");
                try args.append(alloc, "-mtune=native");
                try args.append(alloc, "-finline-functions");
                try args.append(alloc, "-ffunction-sections");
                try args.append(alloc, "-fdata-sections");
                try args.append(alloc, "-Wl,--gc-sections");
                try args.append(alloc, "-fno-stack-protector");
                try args.append(alloc, "-fno-unwind-tables");
                try args.append(alloc, "-fno-asynchronous-unwind-tables");
                try args.append(alloc, "-fno-ident");
                try args.append(alloc, "-Wl,--build-id=none");
                try args.append(alloc, "-fvisibility=hidden");
                try args.append(alloc, "-s");
                try args.append(alloc, "-fomit-frame-pointer");
                try args.append(alloc, "-fstrict-aliasing");
                try args.append(alloc, "-fno-semantic-interposition");
                try args.append(alloc, "-fno-plt");
                try args.append(alloc, "-fmerge-all-constants");
                try args.append(alloc, "-fwhole-program");
            } else {
                try args.append(alloc, if (flags.is_less_mode) "-Os" else "-O1");
            }
        }

        if (!flags.uses_http) {
            try args.append(alloc, "-DFLINT_NO_HTTP");
        } else {
            try args.append(alloc, "-lcurl");
        }

        try args.append(alloc, "-Wno-unused-value");

        return args.toOwnedSlice(alloc);
    }
};

const ZigCompiler = struct {
    pub fn getArgsExtended(self: ZigCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool, flags: *FlintFlags) ![]const []const u8 {
        _ = self;
        _ = has_pch;
        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "zig");
        try args.append(alloc, "cc");

        if (!is_run) {
            try args.append(alloc, "-target");

            const is_http = flags.uses_http;

            switch (flags.cpu_arch) {
                .x86_64 => try args.append(alloc, if (is_http) "x86_64-linux-gnu" else "x86_64-linux-musl"),
                .aarch => try args.append(alloc, if (is_http) "aarch64-linux-gnu" else "aarch64-linux-musl"),
                .baseline => try args.append(alloc, if (is_http) "native-linux-gnu" else "native-linux-musl"),
            }
        }

        try args.append(alloc, rt);
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");

        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        const arena_macro = try std.fmt.allocPrint(alloc, "-DARENA_CAPACITY={d}ULL", .{flags.arena_size});
        try args.append(alloc, arena_macro);

        const persist_macro = try std.fmt.allocPrint(alloc, "-DPERSISTENT_CAPACITY={d}ULL", .{flags.persist_size});
        try args.append(alloc, persist_macro);

        if (flags.is_static) {
            try args.append(alloc, "-static");
        }

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        if (is_run) {
            try args.append(alloc, "-O0");
        } else {
            if (flags.is_release) {
                try args.append(alloc, if (flags.is_less_mode) "-Oz" else "-O3");
                try args.append(alloc, "-flto");
                try args.append(alloc, "-ffunction-sections");
                try args.append(alloc, "-fdata-sections");
                try args.append(alloc, "-Wl,--gc-sections");
                try args.append(alloc, "-fno-unwind-tables");
                try args.append(alloc, "-fno-asynchronous-unwind-tables");
                try args.append(alloc, "-fno-ident");
                try args.append(alloc, "-Wl,--build-id=none");
                try args.append(alloc, "-fno-stack-protector");
                try args.append(alloc, "-fvisibility=hidden");
                try args.append(alloc, "-s");
            } else {
                try args.append(alloc, if (flags.is_less_mode) "-Os" else "-O1");
            }
        }

        try args.append(alloc, "-DFLINT_NO_HTTP");

        try args.append(alloc, "-Wno-unused-value");

        return args.toOwnedSlice(alloc);
    }
};

const TccCompiler = struct {
    pub fn getArgsExtended(self: TccCompiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, flags: *FlintFlags) ![]const []const u8 {
        _ = self;

        var args = std.ArrayList([]const u8).empty;

        try args.append(alloc, "tcc");
        try args.append(alloc, rt);
        try args.append(alloc, "-x");
        try args.append(alloc, "c");
        try args.append(alloc, "-");
        try args.append(alloc, "-I.");
        try args.append(alloc, if (pre) "-I/usr/share/flint" else "-I.");

        const arena_macro = try std.fmt.allocPrint(alloc, "-DARENA_CAPACITY={d}ULL", .{flags.arena_size});
        try args.append(alloc, arena_macro);

        const persist_macro = try std.fmt.allocPrint(alloc, "-DPERSISTENT_CAPACITY={d}ULL", .{flags.persist_size});
        try args.append(alloc, persist_macro);

        try args.append(alloc, "-o");
        try args.append(alloc, out_exe);

        if (flags.uses_http) {
            try args.append(alloc, "-lcurl");
        } else {
            try args.append(alloc, "-DFLINT_NO_HTTP");
        }
        try args.append(alloc, "-s");
        try args.append(alloc, "-b");

        return args.toOwnedSlice(alloc);
    }
};

pub const Compiler = union(enum) {
    clang: ClangCompiler,
    gcc: GccCompiler,
    tcc: TccCompiler,
    zigcc: ZigCompiler,
    musl: MuslCompiler,

    pub fn getArgsExtended(self: Compiler, alloc: std.mem.Allocator, out_exe: []const u8, rt: []const u8, pre: bool, is_run: bool, has_pch: bool, flags: *FlintFlags) ![]const []const u8 {
        return switch (self) {
            .tcc => |t| t.getArgsExtended(alloc, out_exe, rt, pre, flags),
            .clang => |c| c.getArgsExtended(alloc, out_exe, rt, pre, is_run, has_pch, flags),
            .gcc => |g| g.getArgsExtended(alloc, out_exe, rt, pre, is_run, has_pch, flags),
            .zigcc => |z| z.getArgsExtended(alloc, out_exe, rt, pre, is_run, has_pch, flags),
            .musl => |m| m.getArgsExtended(alloc, out_exe, rt, pre, is_run, has_pch, flags),
        };
    }
};

fn getBestCCompiler(alloc: std.mem.Allocator, is_run: bool, io_sys: std.Io, flags: *FlintFlags) Compiler {
    if (cached_compiler) |c| return c;

    if (is_run) {
        if (isCompilerPresent(alloc, io_sys, "tcc")) {
            const r = Compiler{ .tcc = TccCompiler{} };
            cached_compiler = r;
            return r;
        }
    }

    const result: Compiler = blk: {
        if (flags.compiler_forced) {
            switch (flags.compiler) {
                .musl => break :blk .{ .musl = MuslCompiler{} },
                .zigcc => break :blk .{ .zigcc = ZigCompiler{} },
                .clang => break :blk .{ .clang = ClangCompiler{} },
                .gcc => break :blk .{ .gcc = GccCompiler{} },
                .tcc => break :blk .{ .tcc = TccCompiler{} },
            }
        }

        if (flags.is_static and !flags.uses_http and isCompilerPresent(alloc, io_sys, "musl-gcc")) break :blk .{ .musl = MuslCompiler{} };
        if (flags.is_static and isCompilerPresent(alloc, io_sys, "zig")) break :blk .{ .zigcc = ZigCompiler{} };

        if (isCompilerPresent(alloc, io_sys, "clang")) break :blk .{ .clang = ClangCompiler{} };
        if (isCompilerPresent(alloc, io_sys, "gcc")) break :blk .{ .gcc = GccCompiler{} };
        if (isCompilerPresent(alloc, io_sys, "tcc")) break :blk .{ .tcc = TccCompiler{} };
        if (isCompilerPresent(alloc, io_sys, "zig")) break :blk .{ .zigcc = ZigCompiler{} };
        if (isCompilerPresent(alloc, io_sys, "musl-gcc")) break :blk .{ .musl = MuslCompiler{} };
        break :blk .{ .clang = ClangCompiler{} };
    };

    cached_compiler = result;
    return result;
}

fn isCompilerPresent(alloc: std.mem.Allocator, io_sys: std.Io, cmd: []const u8) bool {
    const env_ptr = cl.getenv("PATH");
    if (env_ptr == null) return false;

    const path_env = std.mem.span(env_ptr);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        const full = std.fs.path.join(alloc, &.{ dir, cmd }) catch continue;
        defer alloc.free(full);
        if (std.Io.Dir.cwd().access(io_sys, full, .{})) |_| return true else |_| continue;
    }
    return false;
}

pub fn parseCapacityBytes(input: []const u8) !u64 {
    if (input.len == 0) return error.EmptyCapacityString;

    var num_part: []const u8 = input;
    var multiplier: u64 = 1;

    if (std.mem.endsWith(u8, input, "GB") or std.mem.endsWith(u8, input, "G")) {
        multiplier = 1024 * 1024 * 1024;
        const suffix_len: usize = if (input[input.len - 1] == 'B') 2 else 1;
        num_part = input[0 .. input.len - suffix_len];
    } else if (std.mem.endsWith(u8, input, "MB") or std.mem.endsWith(u8, input, "M")) {
        multiplier = 1024 * 1024;
        const suffix_len: usize = if (input[input.len - 1] == 'B') 2 else 1;
        num_part = input[0 .. input.len - suffix_len];
    } else if (std.mem.endsWith(u8, input, "KB") or std.mem.endsWith(u8, input, "K")) {
        multiplier = 1024;
        const suffix_len: usize = if (input[input.len - 1] == 'B') 2 else 1;
        num_part = input[0 .. input.len - suffix_len];
    } else if (std.mem.endsWith(u8, input, "B")) {
        multiplier = 1;
        num_part = input[0 .. input.len - 1];
    }

    const val = std.fmt.parseInt(u64, num_part, 10) catch {
        return error.InvalidNumberFormat;
    };

    return val * multiplier;
}

const ok = void{};
