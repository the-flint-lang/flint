const std = @import("std");
const ast = @import("../parser/ast.zig");
const AstNode = ast.AstNode;
const AstTree = ast.AstTree;
const NodeIndex = ast.NodeIndex;
const StringPool = ast.StringPool;
const StringId = ast.StringId;
const Token = @import("../lexer/structs/token.zig").Token;
const sym = @import("./symbol_table.zig");
const SymbolTable = sym.SymbolTable;
const FlintType = sym.FlintType;
const IoHelpers = @import("../../core/helpers/structs/structs.zig").IoHelpers;
const DiagnosticBuilder = @import("../errors/diagnostics.zig").DiagnosticBuilder;
const DiagnosticLabel = @import("../errors/diagnostics.zig").DiagnosticLabel;

pub const TypeChecker = struct {
    allocator: std.mem.Allocator,
    tree: *const AstTree,
    pool: *StringPool,
    global_scope: *SymbolTable,
    current_scope: *SymbolTable,

    current_function_return_type: ?FlintType = null,
    pipe_injected_type: ?FlintType = null,

    io: IoHelpers,
    file_path: []const u8,
    source: []const u8,
    had_error: bool = false,

    fn defineBuiltin(global: *SymbolTable, alloc: std.mem.Allocator, pool: *StringPool, name: []const u8, ret: FlintType, sig: ?[]const FlintType) !void {
        const id = try pool.intern(alloc, name);
        _ = global.define(id, ret, true, 0, 0, null, sig);
    }

    pub fn init(allocator: std.mem.Allocator, tree: *const AstTree, pool: *StringPool, file_path: []const u8, source: []const u8, io: IoHelpers) !TypeChecker {
        const global = try allocator.create(SymbolTable);
        global.* = SymbolTable.init(allocator, null);

        // global functions
        try defineBuiltin(global, allocator, pool, "print", .t_void, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "printerr", .t_void, &[_]FlintType{.t_any});
        // try defineBuiltin(global, allocator, pool, "len", .t_int, &[_]FlintType{.t_any});
        // try defineBuiltin(global, allocator, pool, "push", .t_void, &[_]FlintType{ .t_arr, .t_any });
        try defineBuiltin(global, allocator, pool, "range", .t_int_arr, &[_]FlintType{ .t_int, .t_int });
        try defineBuiltin(global, allocator, pool, "if_fail", .t_any, &[_]FlintType{ .t_val, .t_string });
        try defineBuiltin(global, allocator, pool, "fallback", .t_any, &[_]FlintType{ .t_val, .t_any });
        try defineBuiltin(global, allocator, pool, "concat", .t_string, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "to_str", .t_string, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "to_int", .t_int, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "parse_json_as", .t_val, &[_]FlintType{ .t_any, .t_string });
        try defineBuiltin(global, allocator, pool, "parse_json", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "ensure", .t_val, &[_]FlintType{ .t_val, .t_bool, .t_string });
        try defineBuiltin(global, allocator, pool, "lines", .t_str_arr, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "grep", .t_str_arr, &[_]FlintType{ .t_any, .t_string });
        try defineBuiltin(global, allocator, pool, "build_str", .t_string, null);
        try defineBuiltin(global, allocator, pool, "chars", .t_str_arr, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "strings_split", .t_str_arr, &[_]FlintType{ .t_string, .t_string });

        // os module
        try defineBuiltin(global, allocator, pool, "os_mkdir", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_rm", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_rm_dir", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_touch", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_ls", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_is_dir", .t_bool, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_is_file", .t_bool, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_file_size", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_mv", .t_val, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "os_copy", .t_val, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "os_exec", .t_string, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_spawn", .t_val, &[_]FlintType{ .t_string, .t_bool });
        try defineBuiltin(global, allocator, pool, "os_env", .t_string, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "os_exit", .t_void, &[_]FlintType{.t_int});
        try defineBuiltin(global, allocator, pool, "os_args", .t_str_arr, &[_]FlintType{.t_void});
        try defineBuiltin(global, allocator, pool, "os_assert", .t_val, &[_]FlintType{ .t_val, .t_string });
        try defineBuiltin(global, allocator, pool, "os_if_fail", .t_any, &[_]FlintType{ .t_val, .t_string });
        try defineBuiltin(global, allocator, pool, "os_is_tty", .t_any, &[_]FlintType{.t_void});
        try defineBuiltin(global, allocator, pool, "os_is_root", .t_bool, &[_]FlintType{.t_void});
        try defineBuiltin(global, allocator, pool, "os_require_root", .t_val, &[_]FlintType{.t_str_arr});
        try defineBuiltin(global, allocator, pool, "os_command_exists", .t_bool, &[_]FlintType{.t_string});

        // io module
        try defineBuiltin(global, allocator, pool, "io_write", .t_val, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "io_read_file", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "io_write_file", .t_val, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "io_read_line", .t_string, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "io_clear", .t_void, &[_]FlintType{.t_void});

        // http module
        try defineBuiltin(global, allocator, pool, "http_fetch", .t_val, &[_]FlintType{.t_string});

        // strings module
        try defineBuiltin(global, allocator, pool, "strings_join", .t_string, &[_]FlintType{ .t_str_arr, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_trim", .t_string, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "strings_count_matches", .t_int, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_replace", .t_string, &[_]FlintType{ .t_string, .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_to_str", .t_string, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "strings_int_to_str", .t_string, &[_]FlintType{.t_int});
        try defineBuiltin(global, allocator, pool, "strings_concat", .t_string, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_to_int", .t_int, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "strings_str_eql", .t_bool, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_lines", .t_str_arr, &[_]FlintType{.t_any});
        try defineBuiltin(global, allocator, pool, "strings_grep", .t_str_arr, &[_]FlintType{ .t_any, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_starts_with", .t_bool, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_ends_with", .t_bool, &[_]FlintType{ .t_string, .t_string });
        try defineBuiltin(global, allocator, pool, "strings_repeat", .t_string, &[_]FlintType{ .t_string, .t_int });

        // json and utils module
        try defineBuiltin(global, allocator, pool, "json_parse", .t_val, &[_]FlintType{.t_string});
        try defineBuiltin(global, allocator, pool, "utils_is_err", .t_bool, &[_]FlintType{.t_val});
        try defineBuiltin(global, allocator, pool, "utils_get_err", .t_string, &[_]FlintType{.t_val});

        // empty constructors
        try defineBuiltin(global, allocator, pool, "int_array", .t_int_arr, &[_]FlintType{});
        try defineBuiltin(global, allocator, pool, "str_array", .t_str_arr, &[_]FlintType{});
        try defineBuiltin(global, allocator, pool, "bool_array", .t_bool_arr, &[_]FlintType{});

        return .{
            .allocator = allocator,
            .tree = tree,
            .pool = pool,
            .global_scope = global,
            .current_scope = global,
            .current_function_return_type = null,
            .pipe_injected_type = null,
            .io = io,
            .file_path = file_path,
            .source = source,
            .had_error = false,
        };
    }

    pub fn check(self: *TypeChecker, root_idx: NodeIndex) !void {
        const program_node = self.tree.getNode(root_idx);
        if (program_node != .program) return;

        for (program_node.program.statements) |stmt_idx| {
            _ = try self.checkNodeIndex(stmt_idx);
        }
    }

    fn checkNodeIndex(self: *TypeChecker, index: NodeIndex) anyerror!FlintType {
        const node = self.tree.getNode(index);
        return switch (node) {
            .var_decl => try self.checkVarDecl(index, node),
            .identifier => try self.checkIdentifier(index, node),
            .literal => try self.checkLiteral(node),
            .binary_expr => try self.checkBinaryExpr(index, node),
            .unary_expr => try self.checkUnaryExpr(index, node),
            .if_stmt => try self.checkIfStmt(node),
            .for_stmt => try self.checkForStmt(node),
            .call_expr => try self.checkCallExpr(index, node),
            .pipeline_expr => try self.checkPipelineExpr(index, node),
            .function_decl => try self.checkFunctionDecl(index, node),
            .return_stmt => try self.checkReturnStmt(node),
            .property_access_expr => try self.checkPropertyAccessExpr(index, node),
            .import_stmt => try self.checkImportStmt(node),
            .array_expr => try self.checkArrayExpr(index, node),
            .dict_expr => try self.checkDictExpr(index, node),
            .index_expr => try self.checkIndexExpr(index, node),
            .catch_expr => try self.checkCatchExpr(index, node),
            .struct_decl => try self.checkStructDecl(index, node),

            .logical_and, .logical_or => |bin| {
                const left_type = try self.checkNodeIndex(bin.left);
                const right_type = try self.checkNodeIndex(bin.right);

                if (left_type != .t_bool or right_type != .t_bool) {
                    self.had_error = true;

                    var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Logical operators ('and', 'or') require boolean operands.", self.source, self.file_path);
                    defer diag.deinit();

                    try diag.addLabel(1, 1, 1, "both sides must evaluate to a boolean", true);
                    try diag.emit(self.io);

                    return .t_error;
                }

                return .t_bool;
            },

            else => .t_unknown,
        };
    }

    fn checkStructDecl(self: *TypeChecker, index: NodeIndex, node: AstNode) !FlintType {
        const decl = node.struct_decl;

        const success = self.global_scope.define(decl.name_id, .t_any, true, 0, 0, index, null);

        if (!success) {
            const name_str = self.pool.get(decl.name_id);
            try self.reportErrorContext(0, 0, @intCast(name_str.len), "A struct or function with this name already exists.");
            return .t_error;
        }

        var field_names = std.AutoHashMap(StringId, void).init(self.allocator);
        defer field_names.deinit();

        for (decl.fields) |field| {
            if (field_names.contains(field.name_id)) {
                const f_str = self.pool.get(field.name_id);
                try self.reportErrorContext(field._type.line, field._type.column, @intCast(f_str.len), "Duplicate field name in struct declaration.");
            } else {
                field_names.put(field.name_id, {}) catch unreachable;
            }

            const field_type = self.tokenToFlintType(field._type);
            if (field_type == .t_unknown) {
                try self.reportErrorContext(field._type.line, field._type.column, @intCast(field._type.value.len), "Unknown type used in struct field.");
            }
        }

        return .t_void;
    }

    // scope management
    fn beginScope(self: *TypeChecker) !void {
        const new_scope = try self.allocator.create(SymbolTable);
        new_scope.* = SymbolTable.init(self.allocator, self.current_scope);
        self.current_scope = new_scope;
    }

    fn endScope(self: *TypeChecker) void {
        if (self.current_scope.enclosing) |parent| {
            self.current_scope = parent;
        }
    }

    fn checkBlock(self: *TypeChecker, statements: []const NodeIndex) !void {
        try self.beginScope();
        defer self.endScope();

        for (statements) |stmt_idx| {
            _ = try self.checkNodeIndex(stmt_idx);
        }
    }

    // semantic rules
    fn checkVarDecl(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const decl = node.var_decl;
        const expr_type = try self.checkNodeIndex(decl.value);

        if (expr_type == .t_void) {
            self.had_error = true;
            var err_line: u32 = 0;
            var err_col: u32 = 0;
            var err_len: u32 = 1;
            self.extractCoords(decl.value, &err_line, &err_col, &err_len);

            var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0282", "Cannot assign void to a variable", self.source, self.file_path);
            defer diag.deinit();

            try diag.addLabel(err_line, err_col, err_len, "this expression returns nothing (`void`)", true);
            diag.help("remove the variable declaration and just call the function");
            try diag.emit(self.io);
            return .t_error;
        }

        var custom_struct_id: ?StringId = null;

        if (decl._type) |type_token| {
            const declared_type = self.tokenToFlintType(type_token);

            if (declared_type == .t_unknown) {
                custom_struct_id = try self.pool.intern(self.allocator, type_token.value);

                if (self.global_scope.lookup(custom_struct_id.?) == null) {
                    try self.reportErrorContext(type_token.line, type_token.column, @intCast(type_token.value.len), "Unknown type. This struct has not been declared.");
                    return .t_error;
                }
            } else if (declared_type != expr_type and expr_type != .t_any and expr_type != .t_error) {
                var diag = DiagnosticBuilder.init(self.allocator, "TYPE ERROR", "E0012", "Type mismatch", self.source, self.file_path);
                defer diag.deinit();
                self.had_error = true;

                const expected_lbl = try std.fmt.allocPrint(self.allocator, "expected `{s}`", .{type_token.value});
                const found_lbl = try std.fmt.allocPrint(self.allocator, "found `{s}`", .{self.flintTypeToStr(expr_type)});

                try diag.addLabel(type_token.line, type_token.column, @intCast(type_token.value.len), expected_lbl, false);

                var v_line: u32 = 0;
                var v_col: u32 = 0;
                var v_len: u32 = 0;
                self.extractCoords(decl.value, &v_line, &v_col, &v_len);
                try diag.addLabel(v_line, v_col, v_len, found_lbl, true);

                const note_str = try std.fmt.allocPrint(self.allocator, "`{s}` is declared as type `{s}`", .{ self.pool.get(decl.name_id), type_token.value });
                diag.note(note_str);

                const help_str = try std.fmt.allocPrint(self.allocator, "convert the value or change the variable type to match the assignment", .{});
                diag.help(help_str);

                try diag.emit(self.io);

                self.allocator.free(expected_lbl);
                self.allocator.free(found_lbl);
                self.allocator.free(note_str);
                self.allocator.free(help_str);

                return .t_error;
            }
        }

        const success = self.current_scope.define(decl.name_id, expr_type, decl.is_const, decl.line, 0, null, null);

        if (!success) {
            const original_sym = self.current_scope.lookup(decl.name_id).?;

            var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0428", "Variable already declared", self.source, self.file_path);
            defer diag.deinit();

            var lines_iter = std.mem.splitScalar(u8, self.source, '\n');
            var curr: u32 = 0;
            var name_col: u32 = 0;
            const target_line_0_indexed = decl.line - 1;
            const var_name = self.pool.get(decl.name_id);

            while (lines_iter.next()) |l| : (curr += 1) {
                if (curr == target_line_0_indexed) {
                    if (std.mem.indexOf(u8, l, var_name)) |idx| {
                        name_col = @intCast(idx);
                    }
                    break;
                }
            }

            const name_len: u32 = @intCast(var_name.len);
            try diag.addLabel(target_line_0_indexed, name_col + name_len, name_len, "redefined here", true);

            const note_str = try std.fmt.allocPrint(self.allocator, "previous definition of `{s}` was at line {d}", .{ var_name, original_sym.line });
            diag.note(note_str);

            diag.help("rename this variable or remove the duplicate declaration");

            try diag.emit(self.io);
            self.allocator.free(note_str);

            return .t_error;
        }

        if (custom_struct_id) |s_id| {
            if (self.current_scope.symbols.getPtr(decl.name_id)) |sym_ptr| {
                sym_ptr.struct_name_id = s_id;
            }
        } else {
            const val_node = self.tree.getNode(decl.value);
            if (val_node == .call_expr) {
                const call = val_node.call_expr;
                const callee_node = self.tree.getNode(call.callee);

                if (callee_node == .identifier and std.mem.eql(u8, self.pool.get(callee_node.identifier.name_id), "parse_json_as")) {
                    if (call.arguments.len > 0) {
                        const arg_node = self.tree.getNode(call.arguments[0]);
                        if (arg_node == .identifier) {
                            const inferred_struct_id = arg_node.identifier.name_id;

                            if (self.global_scope.lookup(inferred_struct_id) != null) {
                                if (self.current_scope.symbols.getPtr(decl.name_id)) |sym_ptr| {
                                    sym_ptr.struct_name_id = inferred_struct_id;
                                }
                            }
                        }
                    }
                }
            }
        }

        return .t_void;
    }

    fn checkIdentifier(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const name_id = node.identifier.name_id;
        const token = node.identifier._type;

        if (self.current_scope.lookup(name_id)) |symbol| {
            return symbol.type;
        }

        self.had_error = true;
        var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0425", "Undefined variable", self.source, self.file_path);
        defer diag.deinit();

        const name_str = self.pool.get(name_id);
        const msg = try std.fmt.allocPrint(self.allocator, "cannot find value `{s}` in this scope", .{name_str});
        try diag.addLabel(token.line, token.column, @intCast(name_str.len), "not found in this scope", true);
        diag.help("did you spell it correctly or forget to declare it?");

        try diag.emit(self.io);
        self.allocator.free(msg);

        return .t_error;
    }

    fn checkLiteral(self: *TypeChecker, node: AstNode) !FlintType {
        _ = self;
        const token = node.literal.token;
        return switch (token._type) {
            .integer_literal_token => .t_int,
            .string_literal_token, .multile_string_literal_token, .char_literal_token => .t_string,
            .true_literal_token, .false_literal_token => .t_bool,
            else => .t_unknown,
        };
    }

    fn checkBinaryExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const op = node.binary_expr.operator;

        if (op._type == .assign_token) {
            const left_node = self.tree.getNode(node.binary_expr.left);

            if (left_node == .identifier) {
                const name_id = left_node.identifier.name_id;
                const name_str = self.pool.get(name_id);

                if (std.mem.eql(u8, name_str, "_")) {
                    return try self.checkNodeIndex(node.binary_expr.right);
                }

                const right_type = try self.checkNodeIndex(node.binary_expr.right);

                if (self.current_scope.lookup(name_id)) |symbol| {
                    if (symbol.is_const) {
                        var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0384", "Cannot reassign to a 'const' variable", self.source, self.file_path);
                        defer diag.deinit();

                        try diag.addLabel(op.line, op.column, 1, "cannot assign twice to immutable variable", true);

                        const note_str = try std.fmt.allocPrint(self.allocator, "`{s}` was defined as `const` at line {d}", .{ name_str, symbol.line });
                        diag.note(note_str);

                        const help_str = try std.fmt.allocPrint(self.allocator, "to allow mutation, change the declaration of `{s}` to use `var` instead of `const`", .{name_str});
                        diag.help(help_str);

                        try diag.emit(self.io);

                        self.allocator.free(note_str);
                        self.allocator.free(help_str);

                        self.had_error = true;
                        return .t_error;
                    }

                    if (symbol.type != right_type and right_type != .t_any and symbol.type != .t_unknown) {
                        try self.reportErrorContext(op.line, op.column, 1, "Type mismatch. Cannot assign a value of a different type to this variable.");
                        return .t_error;
                    }
                    return symbol.type;
                } else {
                    const id_node = left_node.identifier._type;
                    try self.reportErrorContext(id_node.line, id_node.column, @intCast(name_str.len), "Assignment to undefined variable.");
                    return .t_error;
                }
            } else if (left_node == .index_expr or left_node == .property_access_expr) {
                _ = try self.checkNodeIndex(node.binary_expr.left);
                return try self.checkNodeIndex(node.binary_expr.right);
            } else {
                try self.reportErrorContext(op.line, op.column, 1, "Invalid assignment target. You can only assign to variables, array indices, or properties.");
                return .t_error;
            }
        }

        const left_type = try self.checkNodeIndex(node.binary_expr.left);
        const right_type = try self.checkNodeIndex(node.binary_expr.right);

        switch (op._type) {
            .plus_token, .minus_token, .star_token, .slash_token, .remainder_token => {
                if (left_type != .t_int or right_type != .t_int) {
                    try self.reportErrorContext(op.line, op.column, 1, "Mathematical operators only work with integers.");
                    return .t_error;
                }
                return .t_int;
            },
            .equal_token, .bang_equal_token, .greater_token, .less_token, .greater_equal_token, .less_equal_token => {
                return .t_bool;
            },
            else => return .t_unknown,
        }
    }

    fn checkUnaryExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const unary = node.unary_expr;
        const right_type = try self.checkNodeIndex(unary.right);
        const op = unary.operator;

        switch (op._type) {
            .minus_token => {
                if (right_type != .t_int and right_type != .t_any and right_type != .t_unknown and right_type != .t_error) {
                    try self.reportErrorContext(op.line, op.column, 1, "Unary '-' operator can only be applied to integers.");
                    return .t_error;
                }
                return .t_int;
            },
            .not_token => {
                if (right_type != .t_bool and right_type != .t_any and right_type != .t_unknown and right_type != .t_error) {
                    try self.reportErrorContext(op.line, op.column, 1, "Unary '!' operator can only be applied to booleans.");
                    return .t_error;
                }
                return .t_bool;
            },
            else => return .t_unknown,
        }
    }

    fn checkIfStmt(self: *TypeChecker, node: AstNode) !FlintType {
        const stmt = node.if_stmt;

        const condition_type = try self.checkNodeIndex(stmt.condition);
        if (condition_type != .t_bool and condition_type != .t_any and condition_type != .t_val and condition_type != .t_unknown) {
            var line: u32 = 0;
            var col: u32 = 0;
            var len: u32 = 1;
            self.extractCoords(stmt.condition, &line, &col, &len);
            try self.reportErrorContext(line, col, len, "Condition in 'if' statement must evaluate to a boolean.");
        }

        try self.checkBlock(stmt.then_branch);

        if (stmt.else_branch) |else_branch| {
            try self.checkBlock(else_branch);
        }

        return .t_void;
    }

    fn checkForStmt(self: *TypeChecker, node: AstNode) !FlintType {
        const stmt = node.for_stmt;
        const iterable_type = try self.checkNodeIndex(stmt.iterable);

        if (iterable_type != .t_int_arr and iterable_type != .t_str_arr and iterable_type != .t_bool_arr and iterable_type != .t_string and iterable_type != .t_any and iterable_type != .t_val and iterable_type != .t_unknown) {
            var line: u32 = 0;
            var col: u32 = 0;
            var len: u32 = 1;
            self.extractCoords(stmt.iterable, &line, &col, &len);
            try self.reportErrorContext(line, col, len, "The target of a 'for' loop must be iterable (array or string).");
        }

        var iter_type: FlintType = .t_any;
        const iterable_node = self.tree.getNode(stmt.iterable);

        if (iterable_type == .t_string) {
            iter_type = .t_string;
        } else if (iterable_node == .array_expr and iterable_node.array_expr.elements.len > 0) {
            iter_type = try self.checkNodeIndex(iterable_node.array_expr.elements[0]);
        } else if (iterable_node == .call_expr) {
            const callee_node = self.tree.getNode(iterable_node.call_expr.callee);
            if (callee_node == .identifier) {
                const func_name = self.pool.get(callee_node.identifier.name_id);
                if (std.mem.eql(u8, func_name, "range")) {
                    iter_type = .t_int;
                } else if (std.mem.eql(u8, func_name, "lines") or std.mem.eql(u8, func_name, "grep") or std.mem.eql(u8, func_name, "chars") or std.mem.eql(u8, func_name, "strings_split")) {
                    iter_type = .t_string;
                }
            }
        }

        try self.beginScope();
        defer self.endScope();

        _ = self.current_scope.define(stmt.iterator_name_id, iter_type, true, 0, 0, null, null);

        for (stmt.body) |body_stmt_idx| {
            _ = try self.checkNodeIndex(body_stmt_idx);
        }

        return .t_void;
    }

    fn checkCallExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const call = node.call_expr;
        const callee_type = try self.checkNodeIndex(call.callee);

        const injected_arg = self.pipe_injected_type;
        self.pipe_injected_type = null;

        const callee_node = self.tree.getNode(call.callee);

        if (callee_node == .identifier) {
            const func_name_id = callee_node.identifier.name_id;
            const func_name_str = self.pool.get(func_name_id);

            if (std.mem.eql(u8, func_name_str, "push")) {
                const total_args = call.arguments.len + (if (injected_arg != null) @as(usize, 1) else 0);

                if (total_args != 2) {
                    self.had_error = true;
                    var err_line: u32 = call.line;
                    var err_col: u32 = 0;
                    var err_len: u32 = @intCast(func_name_str.len);
                    self.extractCoords(call.callee, &err_line, &err_col, &err_len);

                    var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0040", "Arity mismatch", self.source, self.file_path);
                    defer diag.deinit();
                    const msg = try std.fmt.allocPrint(self.allocator, "the 'push' function takes 2 arguments but {d} were supplied", .{total_args});
                    try diag.addLabel(err_line, err_col, err_len, msg, true);
                    try diag.emit(self.io);
                    self.allocator.free(msg);
                    return .t_error;
                }

                var arr_type: FlintType = undefined;
                var val_type: FlintType = undefined;
                var val_node_idx: NodeIndex = undefined;

                if (injected_arg) |inj| {
                    arr_type = inj;
                    val_node_idx = call.arguments[0];
                    val_type = try self.checkNodeIndex(val_node_idx);
                } else {
                    arr_type = try self.checkNodeIndex(call.arguments[0]);
                    val_node_idx = call.arguments[1];
                    val_type = try self.checkNodeIndex(val_node_idx);
                }

                var type_error: ?[]const u8 = null;
                if (arr_type == .t_int_arr and val_type != .t_int and val_type != .t_any) {
                    type_error = "Type mismatch. Cannot push a non-integer into an int_array.";
                } else if (arr_type == .t_str_arr and val_type != .t_string and val_type != .t_any) {
                    type_error = "Type mismatch. Cannot push a non-string into a str_array.";
                } else if (arr_type == .t_bool_arr and val_type != .t_bool and val_type != .t_any) {
                    type_error = "Type mismatch. Cannot push a non-boolean into a bool_array.";
                } else if (arr_type != .t_int_arr and arr_type != .t_str_arr and arr_type != .t_bool_arr and arr_type != .t_any) {
                    type_error = "First argument of 'push' must be an array.";
                }

                if (type_error) |err_msg| {
                    self.had_error = true;
                    var err_line: u32 = 0;
                    var err_col: u32 = 0;
                    var err_len: u32 = 1;
                    self.extractCoords(val_node_idx, &err_line, &err_col, &err_len);

                    var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Mismatched push type", self.source, self.file_path);
                    defer diag.deinit();
                    try diag.addLabel(err_line, err_col, err_len, err_msg, true);
                    try diag.emit(self.io);
                    return .t_error;
                }
                return .t_void;
            }

            if (std.mem.eql(u8, func_name_str, "len")) {
                const total_args = call.arguments.len + (if (injected_arg != null) @as(usize, 1) else 0);

                if (total_args != 1) {
                    self.had_error = true;
                    var err_line: u32 = call.line;
                    var err_col: u32 = 0;
                    var err_len: u32 = @intCast(func_name_str.len);
                    self.extractCoords(call.callee, &err_line, &err_col, &err_len);

                    var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0040", "Arity mismatch", self.source, self.file_path);
                    defer diag.deinit();
                    const msg = try std.fmt.allocPrint(self.allocator, "the 'len' function takes 1 argument but {d} were supplied", .{total_args});
                    try diag.addLabel(err_line, err_col, err_len, msg, true);
                    try diag.emit(self.io);
                    self.allocator.free(msg);
                    return .t_int;
                }

                var arg_type: FlintType = undefined;
                var err_target_node: NodeIndex = call.callee;

                if (injected_arg) |inj| {
                    arg_type = inj;
                } else {
                    err_target_node = call.arguments[0];
                    arg_type = try self.checkNodeIndex(err_target_node);
                }

                if (arg_type != .t_str_arr and arg_type != .t_int_arr and arg_type != .t_bool_arr and arg_type != .t_string and arg_type != .t_any) {
                    self.had_error = true;
                    var err_line: u32 = 0;
                    var err_col: u32 = 0;
                    var err_len: u32 = 1;
                    self.extractCoords(err_target_node, &err_line, &err_col, &err_len);

                    var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Invalid len target", self.source, self.file_path);
                    defer diag.deinit();
                    try diag.addLabel(err_line, err_col, err_len, "The 'len' function only accepts arrays or strings.", true);
                    try diag.emit(self.io);
                    return .t_error;
                }
                return .t_int;
            }

            if (self.current_scope.lookup(func_name_id)) |symbol| {
                var is_user_func = false;
                var func_decl: AstNode = undefined;

                if (symbol.node) |sym_node_idx| {
                    const n = self.tree.getNode(sym_node_idx);
                    if (n == .function_decl) {
                        is_user_func = true;
                        func_decl = n;
                    }
                }

                const is_builtin = (symbol.node == null and symbol.line == 0) or symbol.builtin_signature != null;

                if (is_user_func or is_builtin) {
                    const provided_args = call.arguments;
                    var expected_len: usize = 0;
                    var has_signature = false;

                    if (is_user_func) {
                        expected_len = func_decl.function_decl.arguments.len;
                        has_signature = true;
                    } else if (is_builtin and symbol.builtin_signature != null) {
                        expected_len = symbol.builtin_signature.?.len;
                        has_signature = true;
                    }

                    const provided_len = provided_args.len + (if (injected_arg != null) @as(usize, 1) else 0);

                    if (has_signature and expected_len != provided_len) {
                        self.had_error = true;
                        var err_line: u32 = call.line;
                        var err_col: u32 = 0;
                        var err_len: u32 = @intCast(func_name_str.len);
                        self.extractCoords(call.callee, &err_line, &err_col, &err_len);

                        var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0040", "Arity mismatch", self.source, self.file_path);
                        defer diag.deinit();

                        const msg = try std.fmt.allocPrint(self.allocator, "this function takes {d} arguments but {d} were supplied", .{ expected_len, provided_len });
                        try diag.addLabel(err_line, err_col, err_len, msg, true);

                        if (injected_arg != null) {
                            diag.note("remember that the pipeline operator `~>` passes the left side as the first argument implicitly");
                        }

                        try diag.emit(self.io);
                        self.allocator.free(msg);
                        return .t_error;
                    }

                    var arg_idx: usize = 0;

                    if (injected_arg) |inj_type| {
                        if (has_signature) {
                            var expected_arg_type: FlintType = .t_any;
                            if (is_user_func) {
                                const a_node = self.tree.getNode(func_decl.function_decl.arguments[0]);
                                expected_arg_type = self.tokenToFlintType(a_node.identifier._type);
                            } else {
                                expected_arg_type = symbol.builtin_signature.?[0];
                            }

                            if (expected_arg_type != inj_type and expected_arg_type != .t_any and inj_type != .t_any and inj_type != .t_error) {
                                self.had_error = true;
                                var err_line: u32 = call.line;
                                var err_col: u32 = 0;
                                var err_len: u32 = @intCast(func_name_str.len);
                                self.extractCoords(call.callee, &err_line, &err_col, &err_len);

                                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Mismatched pipeline argument type", self.source, self.file_path);
                                defer diag.deinit();

                                const e_str = self.flintTypeToStr(expected_arg_type);
                                const f_str = self.flintTypeToStr(inj_type);
                                const msg = try std.fmt.allocPrint(self.allocator, "pipeline expected `{s}`, but left side passed `{s}`", .{ e_str, f_str });

                                try diag.addLabel(err_line, err_col, err_len, msg, true);
                                try diag.emit(self.io);
                                self.allocator.free(msg);
                                return .t_error;
                            }
                        }
                        arg_idx += 1;
                    }

                    for (provided_args) |provided_arg_idx| {
                        const provided_arg_type = try self.checkNodeIndex(provided_arg_idx);

                        if (has_signature) {
                            var expected_arg_type: FlintType = .t_any;
                            if (is_user_func) {
                                const a_node = self.tree.getNode(func_decl.function_decl.arguments[arg_idx]);
                                expected_arg_type = self.tokenToFlintType(a_node.identifier._type);
                            } else {
                                expected_arg_type = symbol.builtin_signature.?[arg_idx];
                            }

                            if (expected_arg_type != provided_arg_type and expected_arg_type != .t_any and provided_arg_type != .t_any and provided_arg_type != .t_error) {
                                self.had_error = true;
                                var err_line: u32 = 0;
                                var err_col: u32 = 0;
                                var err_len: u32 = 1;
                                self.extractCoords(provided_arg_idx, &err_line, &err_col, &err_len);

                                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Mismatched argument type", self.source, self.file_path);
                                defer diag.deinit();

                                const e_str = self.flintTypeToStr(expected_arg_type);
                                const f_str = self.flintTypeToStr(provided_arg_type);
                                const msg = try std.fmt.allocPrint(self.allocator, "expected `{s}`, found `{s}`", .{ e_str, f_str });

                                try diag.addLabel(err_line, err_col, err_len, msg, true);
                                try diag.emit(self.io);
                                self.allocator.free(msg);
                                return .t_error;
                            }
                        }
                        arg_idx += 1;
                    }

                    return symbol.type;
                }

                self.had_error = true;
                var err_line: u32 = call.line;
                var err_col: u32 = 0;
                var err_len: u32 = @intCast(func_name_str.len);
                self.extractCoords(call.callee, &err_line, &err_col, &err_len);

                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0618", "Not a function", self.source, self.file_path);
                defer diag.deinit();

                const lbl_msg = try std.fmt.allocPrint(self.allocator, "expected a function, found `{s}`", .{self.flintTypeToStr(symbol.type)});
                try diag.addLabel(err_line, err_col, err_len, lbl_msg, true);
                diag.note("variables cannot be called like functions");
                try diag.emit(self.io);
                self.allocator.free(lbl_msg);

                return .t_error;
            }
        }

        for (call.arguments) |arg_idx| {
            _ = try self.checkNodeIndex(arg_idx);
        }

        return callee_type;
    }

    fn checkPipelineExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const pipe = node.pipeline_expr;
        const left_type = try self.checkNodeIndex(pipe.left);

        const right_node = self.tree.getNode(pipe.right_call);

        if (right_node != .call_expr) {
            self.had_error = true;
            var line: u32 = 0;
            var col: u32 = 0;
            var len: u32 = 1;
            self.extractCoords(pipe.right_call, &line, &col, &len);

            var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0618", "Invalid pipeline target", self.source, self.file_path);
            defer diag.deinit();
            try diag.addLabel(line, col, len, "the right side of a pipeline `~>` operator must be a function call", true);
            try diag.emit(self.io);
            return .t_error;
        }

        const prev_injected = self.pipe_injected_type;
        self.pipe_injected_type = left_type;

        const right_type = try self.checkNodeIndex(pipe.right_call);

        self.pipe_injected_type = prev_injected;

        return right_type;
    }

    fn checkFunctionDecl(self: *TypeChecker, index: NodeIndex, node: AstNode) !FlintType {
        const decl = node.function_decl;
        const return_type = self.tokenToFlintType(decl.return_type);

        _ = self.current_scope.define(decl.name_id, return_type, true, decl.return_type.line, 0, index, null);

        if (decl.is_extern) return .t_void;

        const previous_return_type = self.current_function_return_type;
        self.current_function_return_type = return_type;
        defer self.current_function_return_type = previous_return_type;

        try self.beginScope();
        defer self.endScope();

        for (decl.arguments) |arg_idx| {
            const arg_node = self.tree.getNode(arg_idx);
            const arg_name_id = arg_node.identifier.name_id;
            const arg_type = self.tokenToFlintType(arg_node.identifier._type);
            _ = self.current_scope.define(arg_name_id, arg_type, true, arg_node.identifier._type.line, 0, null, null);
        }

        for (decl.body) |stmt_idx| {
            _ = try self.checkNodeIndex(stmt_idx);
        }

        return .t_void;
    }

    fn checkReturnStmt(self: *TypeChecker, node: AstNode) !FlintType {
        const stmt = node.return_stmt;
        var actual_return_type: FlintType = .t_void;

        var err_line: u32 = 0;
        var err_col: u32 = 0;
        var err_len: u32 = 6;

        if (stmt.value) |val_idx| {
            actual_return_type = try self.checkNodeIndex(val_idx);
            self.extractCoords(val_idx, &err_line, &err_col, &err_len);
        }

        if (self.current_function_return_type) |expected_type| {
            if (expected_type != actual_return_type and expected_type != .t_any and actual_return_type != .t_any and actual_return_type != .t_error) {
                self.had_error = true;
                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Mismatched return type", self.source, self.file_path);
                defer diag.deinit();
                const expected_str = self.flintTypeToStr(expected_type);
                const found_str = self.flintTypeToStr(actual_return_type);
                const lbl_msg = try std.fmt.allocPrint(self.allocator, "expected `{s}`, found `{s}`", .{ expected_str, found_str });

                try diag.addLabel(err_line, err_col, err_len, lbl_msg, true);
                try diag.emit(self.io);
                self.allocator.free(lbl_msg);
                return .t_error;
            }
        } else {
            self.had_error = true;

            const r_line: u32 = err_line;
            const r_col: u32 = err_col;
            const r_len: u32 = err_len;

            var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0515", "Return outside of function", self.source, self.file_path);
            defer diag.deinit();

            try diag.addLabel(r_line, r_col, r_len, "cannot return at the global scope", true);
            diag.help("remove this return statement or wrap it inside a function");
            try diag.emit(self.io);
            return .t_error;
        }

        return .t_void;
    }

    fn checkPropertyAccessExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const prop_access = node.property_access_expr;

        const prev_had_error = self.had_error;
        const obj_type = self.checkNodeIndex(prop_access.object) catch .t_unknown;

        const obj_node = self.tree.getNode(prop_access.object);

        if (obj_node == .identifier) {
            const obj_name_id = obj_node.identifier.name_id;
            const obj_name_str = self.pool.get(obj_name_id);
            const prop_name_str = self.pool.get(prop_access.property_name_id);

            if (self.current_scope.lookup(obj_name_id)) |symbol| {
                if (symbol.struct_name_id) |s_id| {
                    if (self.global_scope.lookup(s_id)) |struct_sym| {
                        if (struct_sym.node) |s_node_idx| {
                            const s_node = self.tree.getNode(s_node_idx);
                            if (s_node == .struct_decl) {
                                for (s_node.struct_decl.fields) |field| {
                                    if (field.name_id == prop_access.property_name_id) {
                                        return self.tokenToFlintType(field._type);
                                    }
                                }

                                var err_line: u32 = 0;
                                var err_col: u32 = 0;
                                var err_len: u32 = 1;
                                self.extractCoords(prop_access.object, &err_line, &err_col, &err_len);

                                const prop_len: u32 = @intCast(prop_name_str.len);
                                const final_col = err_col + 1 + prop_len;

                                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0609", "Property does not exist", self.source, self.file_path);
                                defer diag.deinit();

                                try diag.addLabel(err_line, final_col, prop_len, "no such property on this struct", true);
                                try diag.emit(self.io);
                                self.had_error = true;
                                return .t_error;
                            }
                        }
                    }
                    self.had_error = true;
                    return .t_error;
                }
            }

            const namespaced_func_name = try std.fmt.allocPrint(self.allocator, "{s}_{s}", .{ obj_name_str, prop_name_str });
            defer self.allocator.free(namespaced_func_name);

            const ns_id = try self.pool.intern(self.allocator, namespaced_func_name);

            if (self.global_scope.lookup(ns_id)) |mod_func_sym| {
                self.had_error = prev_had_error;
                return mod_func_sym.type;
            } else {
                if (std.mem.eql(u8, obj_name_str, "os") or std.mem.eql(u8, obj_name_str, "io") or std.mem.eql(u8, obj_name_str, "http") or std.mem.eql(u8, obj_name_str, "strings") or std.mem.eql(u8, obj_name_str, "json") or std.mem.eql(u8, obj_name_str, "utils")) {
                    self.had_error = true;
                    var err_line: u32 = 0;
                    var err_col: u32 = 0;
                    var err_len: u32 = 1;
                    self.extractCoords(prop_access.object, &err_line, &err_col, &err_len);

                    const prop_len: u32 = @intCast(prop_name_str.len);
                    const final_col = err_col + 1 + prop_len;

                    var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0609", "Function does not exist in module", self.source, self.file_path);
                    defer diag.deinit();

                    try diag.addLabel(err_line, final_col, prop_len, "module does not export this function", true);

                    const note_str = try std.fmt.allocPrint(self.allocator, "the module `{s}` has no function called `{s}`", .{ obj_name_str, prop_name_str });
                    diag.note(note_str);

                    try diag.emit(self.io);
                    self.allocator.free(note_str);
                    return .t_error;
                }
            }
        }

        if (obj_type == .t_error or obj_type == .t_unknown) return .t_error;
        if (obj_type == .t_any) return .t_any;

        var err_line: u32 = 0;
        var err_col: u32 = 0;
        var err_len: u32 = 1;
        self.extractCoords(prop_access.object, &err_line, &err_col, &err_len);

        const prop_name_str = self.pool.get(prop_access.property_name_id);
        const prop_len: u32 = @intCast(prop_name_str.len);
        const final_col = err_col + 1 + prop_len;

        var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0609", "Invalid property access", self.source, self.file_path);
        defer diag.deinit();

        const type_str = self.flintTypeToStr(obj_type);
        const msg = try std.fmt.allocPrint(self.allocator, "type `{s}` has no properties", .{type_str});

        try diag.addLabel(err_line, final_col, prop_len, msg, true);
        try diag.emit(self.io);
        self.allocator.free(msg);

        self.had_error = true;
        return .t_error;
    }

    // imports and data structures
    fn checkImportStmt(self: *TypeChecker, node: AstNode) !FlintType {
        const stmt = node.import_stmt;
        const module_id = stmt.alias_id orelse try self.pool.intern(self.allocator, stmt.path);
        _ = self.current_scope.define(module_id, .t_any, true, 0, 0, null, null);
        return .t_void;
    }

    fn checkArrayExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const arr = node.array_expr;

        if (arr.elements.len == 0) return .t_str_arr;

        const first_type = try self.checkNodeIndex(arr.elements[0]);
        var array_has_error = false;

        var first_line: u32 = 0;
        var first_col: u32 = 0;
        var first_len: u32 = 1;
        self.extractCoords(arr.elements[0], &first_line, &first_col, &first_len);

        for (arr.elements[1..]) |elem_idx| {
            const elem_type = try self.checkNodeIndex(elem_idx);

            if (elem_type != first_type and first_type != .t_any and elem_type != .t_any and elem_type != .t_error) {
                self.had_error = true;
                array_has_error = true;

                var err_line: u32 = 0;
                var err_col: u32 = 0;
                var err_len: u32 = 1;
                self.extractCoords(elem_idx, &err_line, &err_col, &err_len);

                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Mismatched types in array", self.source, self.file_path);

                const expected_str = self.flintTypeToStr(first_type);
                const found_str = self.flintTypeToStr(elem_type);

                const first_msg = try std.fmt.allocPrint(self.allocator, "type inferred as `{s}` here", .{expected_str});
                try diag.addLabel(first_line, first_col, first_len, first_msg, false);

                const lbl_msg = try std.fmt.allocPrint(self.allocator, "found `{s}`", .{found_str});
                try diag.addLabel(err_line, err_col, err_len, lbl_msg, true);

                diag.note("arrays in Flint must contain elements of the same type");
                try diag.emit(self.io);

                self.allocator.free(first_msg);
                self.allocator.free(lbl_msg);
                diag.deinit();
            }
        }

        if (array_has_error) return .t_error;

        return switch (first_type) {
            .t_int => .t_int_arr,
            .t_string => .t_str_arr,
            .t_bool => .t_bool_arr,
            else => .t_str_arr,
        };
    }

    fn checkDictExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const dict = node.dict_expr;

        for (dict.entries) |entry| {
            const key_type = try self.checkNodeIndex(entry.key);

            if (key_type != .t_string and key_type != .t_any and key_type != .t_error) {
                self.had_error = true;
                var err_line: u32 = 0;
                var err_col: u32 = 0;
                var err_len: u32 = 1;
                self.extractCoords(entry.key, &err_line, &err_col, &err_len);

                var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0308", "Invalid dictionary key type", self.source, self.file_path);
                defer diag.deinit();

                const found_str = self.flintTypeToStr(key_type);
                const msg = try std.fmt.allocPrint(self.allocator, "expected `string`, found `{s}`", .{found_str});

                try diag.addLabel(err_line, err_col, err_len, msg, true);
                diag.note("dictionary keys must be valid strings");
                try diag.emit(self.io);
                self.allocator.free(msg);

                return .t_error;
            }

            _ = try self.checkNodeIndex(entry.value);
        }

        return .t_val;
    }

    // indexing and error handling
    fn checkIndexExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const idx = node.index_expr;

        const left_type = try self.checkNodeIndex(idx.left);
        _ = try self.checkNodeIndex(idx.index);

        if (left_type != .t_int_arr and left_type != .t_str_arr and left_type != .t_bool_arr and left_type != .t_val and left_type != .t_any and left_type != .t_error) {
            self.had_error = true;
            var err_line: u32 = 0;
            var err_col: u32 = 0;
            var err_len: u32 = 1;
            self.extractCoords(idx.left, &err_line, &err_col, &err_len);

            var diag = DiagnosticBuilder.init(self.allocator, "SEMANTIC ERROR", "E0608", "Cannot index into a value of this type", self.source, self.file_path);
            defer diag.deinit();

            const t_str = self.flintTypeToStr(left_type);
            const msg = try std.fmt.allocPrint(self.allocator, "type `{s}` cannot be indexed", .{t_str});

            try diag.addLabel(err_line, err_col, err_len, msg, true);
            diag.note("only arrays and dynamic objects (`val`) support bracket `[ ]` indexing");
            try diag.emit(self.io);
            self.allocator.free(msg);

            return .t_error;
        }

        return .t_any;
    }

    fn checkCatchExpr(self: *TypeChecker, _: NodeIndex, node: AstNode) !FlintType {
        const catch_stmt = node.catch_expr;
        const expr_type = try self.checkNodeIndex(catch_stmt.expression);

        if (expr_type == .t_error) return .t_error;

        try self.beginScope();
        defer self.endScope();

        _ = self.current_scope.define(catch_stmt.error_identifier_id, .t_string, true, 0, 0, null, null);

        for (catch_stmt.body) |stmt_idx| {
            _ = try self.checkNodeIndex(stmt_idx);
        }

        return expr_type;
    }

    // utils and diagnostics
    fn flintTypeToStr(self: *TypeChecker, f_type: FlintType) []const u8 {
        _ = self;
        return switch (f_type) {
            .t_int => "int",
            .t_string => "string",
            .t_bool => "bool",
            .t_val => "val",

            .t_int_arr => "int_array",
            .t_str_arr => "str_array",
            .t_bool_arr => "bool_array",

            .t_void => "void",
            .t_any => "any",
            .t_error => "error",
            .t_unknown => "unknown struct",
        };
    }

    fn extractCoords(self: *TypeChecker, index: NodeIndex, line: *u32, col: *u32, len: *u32) void {
        const node = self.tree.getNode(index);

        switch (node) {
            .literal => {
                line.* = node.literal.token.line;
                col.* = node.literal.token.column;

                var actual_len: u32 = @intCast(node.literal.token.value.len);
                const t_type = node.literal.token._type;

                if (t_type == .string_literal_token or t_type == .char_literal_token) {
                    actual_len += 2;
                } else if (t_type == .multile_string_literal_token) {
                    actual_len += 2;
                }
                len.* = actual_len;
            },
            .identifier => {
                line.* = node.identifier._type.line;
                col.* = node.identifier._type.column;
                len.* = @intCast(self.pool.get(node.identifier.name_id).len);
            },
            .binary_expr => {
                line.* = node.binary_expr.operator.line;
                col.* = node.binary_expr.operator.column;
                len.* = @intCast(node.binary_expr.operator.value.len);
            },
            .unary_expr => {
                line.* = node.unary_expr.operator.line;
                col.* = node.unary_expr.operator.column;
                len.* = @intCast(node.unary_expr.operator.value.len);
            },
            .property_access_expr => {
                line.* = node.property_access_expr.line;
                col.* = 0;
                len.* = @intCast(self.pool.get(node.property_access_expr.property_name_id).len);
            },
            .call_expr => {
                self.extractCoords(node.call_expr.callee, line, col, len);
            },
            .pipeline_expr => {
                self.extractCoords(node.pipeline_expr.right_call, line, col, len);
            },
            .array_expr, .dict_expr => {
                len.* = 1;
            },
            .import_stmt => {
                len.* = 6;
            },
            .index_expr => {
                self.extractCoords(node.index_expr.left, line, col, len);
            },
            .catch_expr => {
                self.extractCoords(node.catch_expr.expression, line, col, len);
            },
            else => {
                len.* = 1;
            },
        }
    }

    fn tokenToFlintType(self: *TypeChecker, token: Token) FlintType {
        _ = self;
        return switch (token._type) {
            .integer_type_token => .t_int,
            .string_type_token, .char_type_token => .t_string,
            .boolean_type_token => .t_bool,
            .value_type_token => .t_val,
            .array_type_token => .t_str_arr,
            else => .t_unknown,
        };
    }

    fn reportErrorContext(self: *TypeChecker, line: u32, end_column: u32, len: u32, message: []const u8) !void {
        self.had_error = true;

        var lines = std.mem.splitScalar(u8, self.source, '\n');
        var current_line: u32 = 0;
        var target_line_text: []const u8 = "";

        while (lines.next()) |l| : (current_line += 1) {
            if (current_line == line) {
                target_line_text = l;
                break;
            }
        }

        const start_col = if (end_column >= len) end_column - len else 0;

        const red = "\x1b[1;31m";
        const cyan = "\x1b[1;36m";
        const bold = "\x1b[1m";
        const reset = "\x1b[0m";

        try self.io.stderr.print("[{s}SEMANTIC ERROR{s}]: {s}{s}{s}\n", .{ red, reset, bold, message, reset });
        try self.io.stderr.print("  {s}~~>{s} {s}:{d}:{d}\n", .{ cyan, reset, self.file_path, line + 1, start_col + 1 });
        try self.io.stderr.print("   {s}|{s}\n", .{ cyan, reset });
        try self.io.stderr.print("{d:2} {s}|{s} {s}\n", .{ line + 1, cyan, reset, target_line_text });
        try self.io.stderr.print("   {s}|{s} ", .{ cyan, reset });

        var i: u32 = 0;
        while (i < start_col and i < target_line_text.len) : (i += 1) {
            if (target_line_text[i] == '\t') {
                try self.io.stderr.print("\t", .{});
            } else {
                try self.io.stderr.print(" ", .{});
            }
        }

        try self.io.stderr.print("{s}^{s}", .{ red, reset });

        if (len > 1) {
            for (1..len) |_| try self.io.stderr.print("{s}~{s}", .{ red, reset });
        }

        try self.io.stderr.print("\n   {s}|{s}\n\n", .{ cyan, reset });
        _ = try self.io.stderr.flush();
    }
};
