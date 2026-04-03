const std = @import("std");
const ast = @import("../parser/ast.zig");
const AstNode = ast.AstNode;
const AstTree = ast.AstTree;
const NodeIndex = ast.NodeIndex;
const StringPool = ast.StringPool;
const FlintType = @import("../analyzer/symbol_table.zig").FlintType;
const TokenType = @import("../lexer/enums/token_type.zig").TokenType;
const Token = @import("../lexer/structs/token.zig").Token;

pub const CEmitter = struct {
    allocator: std.mem.Allocator,
    tree: *const AstTree,
    pool: *StringPool,
    temp_counter: usize = 0,
    source_file: []const u8,
    is_run: bool,

    built_ins: [16][]const u8,

    node_types: std.AutoHashMap(NodeIndex, FlintType),
    current_placeholder_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, tree: *const AstTree, pool: *StringPool, node_types: std.AutoHashMap(NodeIndex, FlintType), source_file: []const u8, is_run: bool) CEmitter {
        return .{
            .allocator = allocator,
            .tree = tree,
            .pool = pool,
            .source_file = source_file,
            .is_run = is_run,
            .built_ins = [_][]const u8{
                "print",  "printerr",          "len",    "push",       "range",  "if_fail", "fallback",
                "concat", "to_str",            "to_int", "parse_json", "ensure", "lines",   "grep",
                "chars",  "os_command_exists",
            },
            .node_types = node_types,
            .current_placeholder_name = null,
        };
    }

    pub fn generate(self: *CEmitter, writer: anytype, root_idx: NodeIndex) !void {
        try writer.writeAll("#include \"flint_rt.h\"\n\n");
        const program = self.tree.getNode(root_idx);

        if (program == .program) {
            for (program.program.statements) |stmt_idx| {
                const stmt = self.tree.getNode(stmt_idx);
                if (stmt == .var_decl) {
                    const val_node = self.tree.getNode(stmt.var_decl.value);
                    if (val_node == .literal) {
                        try self.visitNodeIndex(stmt_idx, writer);
                        try writer.writeAll(";\n");
                    }
                }
            }
            try writer.writeAll("\n");

            for (program.program.statements) |stmt_idx| {
                const stmt = self.tree.getNode(stmt_idx);
                switch (stmt) {
                    .function_decl => {
                        try self.visitFunctionDecl(stmt, writer);
                        try writer.writeAll("\n");
                    },
                    .struct_decl => {
                        try self.visitStructDecl(stmt, writer);
                        try writer.writeAll("\n");
                    },
                    else => {},
                }
            }
        }

        try writer.writeAll("int main(int argc, char** argv) {\n");
        try writer.writeAll("    flint_init(argc, argv);\n\n");

        if (program == .program) {
            for (program.program.statements) |stmt_idx| {
                const stmt = self.tree.getNode(stmt_idx);
                const is_literal_var = if (stmt == .var_decl) (self.tree.getNode(stmt.var_decl.value) == .literal) else false;

                if (stmt != .function_decl and stmt != .struct_decl and !is_literal_var) {
                    try writer.writeAll("    ");
                    try self.visitNodeIndex(stmt_idx, writer);
                    try writer.writeAll(";\n");
                }
            }
        }

        try writer.writeAll("\n    flint_deinit();\n");
        try writer.writeAll("    return 0;\n}\n");
    }

    fn containsPlaceholder(self: *CEmitter, index: NodeIndex) bool {
        const node = self.tree.getNode(index);
        switch (node) {
            .identifier => return std.mem.eql(u8, self.pool.get(node.identifier.name_id), "_"),
            .binary_expr => return self.containsPlaceholder(node.binary_expr.left) or self.containsPlaceholder(node.binary_expr.right),
            .unary_expr => return self.containsPlaceholder(node.unary_expr.right),
            .call_expr => {
                if (self.containsPlaceholder(node.call_expr.callee)) return true;
                for (node.call_expr.arguments) |arg| {
                    if (self.containsPlaceholder(arg)) return true;
                }
                return false;
            },
            .property_access_expr => return self.containsPlaceholder(node.property_access_expr.object),
            .index_expr => return self.containsPlaceholder(node.index_expr.left) or self.containsPlaceholder(node.index_expr.index),
            .array_expr => {
                for (node.array_expr.elements) |el| {
                    if (self.containsPlaceholder(el)) return true;
                }
                return false;
            },
            .dict_expr => {
                for (node.dict_expr.entries) |entry| {
                    if (self.containsPlaceholder(entry.key) or self.containsPlaceholder(entry.value)) return true;
                }
                return false;
            },
            .pipeline_expr => return self.containsPlaceholder(node.pipeline_expr.left) or self.containsPlaceholder(node.pipeline_expr.right_call),
            .catch_expr => {
                if (self.containsPlaceholder(node.catch_expr.expression)) return true;
                for (node.catch_expr.body) |stmt| {
                    if (self.containsPlaceholder(stmt)) return true;
                }
                return false;
            },
            else => return false,
        }
    }

    // checks if the function is a candidate for inline
    fn shouldInline(self: *CEmitter, body: []const NodeIndex) bool {
        if (body.len > 5) return false;

        for (body) |stmt_idx| {
            const stmt = self.tree.getNode(stmt_idx);
            if (stmt == .for_stmt) return false;
        }

        return true;
    }

    fn visitFunctionDecl(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const func = node.function_decl;
        if (func.is_extern) return;

        const ret_type = switch (func.return_type._type) {
            .void_token => "void",
            .integer_type_token => "long long",
            .value_type_token => "FlintValue",
            .array_type_token => "flint_str_array",
            .boolean_type_token => "bool",
            else => "flint_str",
        };

        if (self.shouldInline(func.body)) {
            try writer.writeAll("static inline ");
        }

        try writer.writeAll(ret_type);
        try writer.writeAll(" ");
        try emitSafeName(writer, self.pool.get(func.name_id));
        try writer.writeAll("(");

        for (func.arguments, 0..) |arg_idx, i| {
            const arg_node = self.tree.getNode(arg_idx);
            const arg_type_tok = arg_node.identifier._type._type;

            const c_type = switch (arg_type_tok) {
                .integer_type_token => "long long",
                .boolean_type_token => "bool",
                .value_type_token => "FlintValue",
                .array_type_token => "flint_str_array",
                else => "flint_str",
            };

            try writer.writeAll(c_type);
            try writer.writeAll(" ");
            try emitSafeName(writer, self.pool.get(arg_node.identifier.name_id));

            if (i < func.arguments.len - 1) {
                try writer.writeAll(", ");
            }
        }

        try writer.writeAll(") {\n");

        for (func.body) |stmt_idx| {
            try writer.writeAll("    ");
            try self.visitNodeIndex(stmt_idx, writer);
            try writer.writeAll(";\n");
        }

        try writer.writeAll("}\n");
    }

    fn visitNodeIndex(self: *CEmitter, index: NodeIndex, writer: anytype) anyerror!void {
        const node = self.tree.getNode(index);
        switch (node) {
            .var_decl => try self.visitVarDecl(node, writer),
            .call_expr => try self.visitCallExpr(node, writer),
            .pipeline_expr => try self.visitPipelineExpr(node, writer),
            .binary_expr => try self.visitBinaryExpr(node, writer),
            .unary_expr => try self.visitUnaryExpr(node, writer),
            .literal => try self.visitLiteral(node, writer),
            .identifier => try self.visitIdentifier(node, writer),
            .if_stmt => try self.visitIfStmt(node, writer),
            .for_stmt => try self.visitForStmt(node, writer),
            .index_expr => try self.visitIndexExpr(node, writer),
            .array_expr => try self.visitArrayExpr(node, writer),
            .dict_expr => try self.visitDictExpr(node, writer),
            .catch_expr => try self.visitCatchExpr(node, writer),
            .struct_decl => try self.visitStructDecl(node, writer),
            .return_stmt => try self.visitReturnStmt(node, writer),
            .property_access_expr => try self.visitPropertyAccessExpr(node, writer),

            .logical_and => |bin| {
                try self.visitNodeIndex(bin.left, writer);
                try writer.writeAll(" && ");
                try self.visitNodeIndex(bin.right, writer);
            },
            .logical_or => |bin| {
                try self.visitNodeIndex(bin.left, writer);
                try writer.writeAll(" || ");
                try self.visitNodeIndex(bin.right, writer);
            },

            else => {
                std.debug.print("Codegen not implemented for: {s}\n", .{@tagName(node)});
                return error.NotImplemented;
            },
        }
    }

    fn visitReturnStmt(self: *CEmitter, node: AstNode, writer: anytype) !void {
        try writer.writeAll("return");
        if (node.return_stmt.value) |val_idx| {
            try writer.writeAll(" ");
            try self.visitNodeIndex(val_idx, writer);
        }
    }

    fn getCTypeFromToken(self: *CEmitter, token: Token) []const u8 {
        _ = self;
        return switch (token._type) {
            .string_type_token => "flint_str",
            .integer_type_token => "long long",
            .float_type_token => "double",
            .boolean_type_token => "bool",
            .value_type_token => "FlintValue",
            .array_type_token => "flint_str_array",
            .identifier_token => token.value,
            else => "void*",
        };
    }

    fn visitStructDecl(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const struct_node = node.struct_decl;
        const s_name = self.pool.get(struct_node.name_id);

        try writer.writeAll("typedef struct {\n");
        for (struct_node.fields) |field| {
            const c_type = self.getCTypeFromToken(field._type);
            try writer.writeAll("    ");
            try writer.writeAll(c_type);
            try writer.writeAll(" ");
            try emitSafeName(writer, self.pool.get(field.name_id));
            try writer.writeAll(";\n");
        }
        try writer.writeAll("} ");
        try emitSafeName(writer, s_name);
        try writer.writeAll(";\n\n");

        try writer.writeAll("static ");
        try emitSafeName(writer, s_name);
        try writer.print(" __parse_{s}_from_val(FlintValue v_envelope) {{\n", .{s_name});
        try writer.writeAll("    FlintDict* d = (v_envelope.type == FLINT_VAL_DICT) ? v_envelope.as.d : NULL;\n");
        try writer.writeAll("    ");
        try emitSafeName(writer, s_name);
        try writer.writeAll(" _obj;\n");

        for (struct_node.fields) |field| {
            const f_name = self.pool.get(field.name_id);
            try writer.print("    FlintValue _v_{s} = d ? flint_dict_get(d, FLINT_STR(\"{s}\")) : (FlintValue){{FLINT_VAL_NULL}};\n", .{ f_name, f_name });

            try writer.writeAll("    _obj.");
            try emitSafeName(writer, f_name);

            if (field._type._type == .string_type_token) {
                try writer.print(" = (_v_{s}.type == FLINT_VAL_STR) ? _v_{s}.as.s : FLINT_STR(\"\");\n", .{ f_name, f_name });
            } else if (field._type._type == .integer_type_token) {
                try writer.print(" = (_v_{s}.type == FLINT_VAL_INT) ? _v_{s}.as.i : 0;\n", .{ f_name, f_name });
            } else if (field._type._type == .boolean_type_token) {
                try writer.print(" = (_v_{s}.type == FLINT_VAL_BOOL) ? _v_{s}.as.b : false;\n", .{ f_name, f_name });
            } else {
                try writer.writeAll(" // TODO: Nested structs not mapped yet\n");
            }
        }

        try writer.writeAll("    return _obj;\n");
        try writer.writeAll("}\n\n");
    }

    fn visitPropertyAccessExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const prop_access = node.property_access_expr;
        const obj_node = self.tree.getNode(prop_access.object);

        if (obj_node == .identifier) {
            const obj_name = self.pool.get(obj_node.identifier.name_id);
            const prop_name = self.pool.get(prop_access.property_name_id);

            const modules = [_][]const u8{ "os", "io", "http", "str", "json", "process", "fs", "term", "utils", "env" };
            var is_module = false;
            for (modules) |m| {
                if (std.mem.eql(u8, obj_name, m)) {
                    is_module = true;
                    break;
                }
            }

            if (is_module) {
                try writer.print("{s}_{s}", .{ obj_name, prop_name });
                return;
            }
        }

        try writer.writeAll("(");
        try self.visitNodeIndex(prop_access.object, writer);
        try writer.writeAll(".");
        try writer.writeAll(self.pool.get(prop_access.property_name_id));
        try writer.writeAll(")");
    }

    fn visitVarDecl(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const decl = node.var_decl;
        const var_name = self.pool.get(decl.name_id);

        if (std.mem.eql(u8, var_name, "_")) {
            try writer.writeAll("(void)(");
            try self.visitNodeIndex(decl.value, writer);
            try writer.writeAll(")");
            return;
        }

        if (!self.is_run and decl.is_const) {
            try writer.writeAll("const ");
        }

        if (self.inferCType(decl.value)) |explicit_type| {
            try writer.writeAll(explicit_type);
            try writer.writeAll(" ");
        } else {
            try writer.writeAll("typeof(");
            try self.visitNodeIndex(decl.value, writer);
            try writer.writeAll(") ");
        }

        try emitSafeName(writer, var_name);
        try writer.writeAll(" = ");
        try self.visitNodeIndex(decl.value, writer);
    }

    fn visitPipelineExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const pipe = node.pipeline_expr;
        const right_call_node = self.tree.getNode(pipe.right_call);
        const right_call = right_call_node.call_expr;

        const has_placeholder = self.containsPlaceholder(pipe.right_call);

        if (has_placeholder) {
            self.temp_counter += 1;
            const temp_name = try std.fmt.allocPrint(self.allocator, "_pipe_val_{d}", .{self.temp_counter});
            defer self.allocator.free(temp_name);

            try writer.writeAll("({\n");
            try writer.writeAll("        typeof(");
            try self.visitNodeIndex(pipe.left, writer);
            try writer.writeAll(") ");
            try writer.writeAll(temp_name);
            try writer.writeAll(" = ");
            try self.visitNodeIndex(pipe.left, writer);
            try writer.writeAll(";\n");

            const prev_placeholder = self.current_placeholder_name;
            self.current_placeholder_name = temp_name;

            try writer.writeAll("        ");
            try self.visitNodeIndex(pipe.right_call, writer);
            try writer.writeAll(";\n");

            self.current_placeholder_name = prev_placeholder;
            try writer.writeAll("    })");
        } else {
            try self.visitNodeIndex(right_call.callee, writer);
            try writer.writeAll("(");
            try self.visitNodeIndex(pipe.left, writer);

            if (right_call.arguments.len > 0) {
                try writer.writeAll(", ");
                for (right_call.arguments, 0..) |arg_idx, i| {
                    try self.visitNodeIndex(arg_idx, writer);
                    if (i < right_call.arguments.len - 1) {
                        try writer.writeAll(", ");
                    }
                }
            }
            try writer.writeAll(")");
        }
    }

    fn visitIfStmt(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const if_node = node.if_stmt;

        try writer.writeAll("if (");
        try self.visitNodeIndex(if_node.condition, writer);
        try writer.writeAll(") {\n");

        for (if_node.then_branch) |stmt_idx| {
            try writer.writeAll("        ");
            try self.visitNodeIndex(stmt_idx, writer);
            try writer.writeAll(";\n");
        }

        try writer.writeAll("    }");

        if (if_node.else_branch) |else_body| {
            try writer.writeAll(" else {\n");
            for (else_body) |stmt_idx| {
                try writer.writeAll("        ");
                try self.visitNodeIndex(stmt_idx, writer);
                try writer.writeAll(";\n");
            }
            try writer.writeAll("    }");
        }
    }

    fn visitForStmt(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const for_node = node.for_stmt;
        self.temp_counter += 1;
        const iter_name = self.temp_counter;
        const target_iter_name = self.pool.get(for_node.iterator_name_id);

        const inferred_type = self.inferCType(for_node.iterable) orelse "flint_str_array";

        try writer.writeAll("    {\n        typeof(");
        try self.visitNodeIndex(for_node.iterable, writer);
        try writer.print(") _iter_{d} = ", .{iter_name});
        try self.visitNodeIndex(for_node.iterable, writer);
        try writer.writeAll(";\n");

        if (std.mem.eql(u8, inferred_type, "flint_str_array") or std.mem.eql(u8, inferred_type, "flint_int_array")) {
            try writer.print("        {s}* _arr_{d} = ({s}*)(void*)&_iter_{d};\n", .{ inferred_type, iter_name, inferred_type, iter_name });
            try writer.print("        for (size_t _i_{d} = 0, _mark_{d} = flint_arena_mark(); _i_{d} < _arr_{d}->count; flint_arena_release(_mark_{d}), _mark_{d} = flint_arena_mark(), _i_{d}++) {{\n", .{ iter_name, iter_name, iter_name, iter_name, iter_name, iter_name, iter_name });
            try writer.print("            typeof(_arr_{d}->items[_i_{d}]) {s} = _arr_{d}->items[_i_{d}];\n", .{ iter_name, iter_name, target_iter_name, iter_name, iter_name });

            for (for_node.body) |stmt_idx| {
                try writer.writeAll("            ");
                try self.visitNodeIndex(stmt_idx, writer);
                try writer.writeAll(";\n");
            }
            try writer.writeAll("        }\n");
        } else {
            try writer.print("        FlintValue* _val_{d} = (FlintValue*)(void*)&_iter_{d};\n", .{ iter_name, iter_name });
            try writer.print("        if (_val_{d}->type == FLINT_VAL_STREAM) {{\n", .{iter_name});
            try writer.print("            flint_stream* _stream_{d} = &_val_{d}->as.stream;\n", .{ iter_name, iter_name });
            try writer.print("            for (size_t _mark_{d} = flint_arena_mark(); _stream_{d}->has_next; flint_arena_release(_mark_{d}), _mark_{d} = flint_arena_mark()) {{\n", .{ iter_name, iter_name, iter_name, iter_name });
            try writer.print("                typeof(flint_stream_next(_stream_{d})) {s} = flint_stream_next(_stream_{d});\n", .{ iter_name, target_iter_name, iter_name });

            for (for_node.body) |stmt_idx| {
                try writer.writeAll("                ");
                try self.visitNodeIndex(stmt_idx, writer);
                try writer.writeAll(";\n");
            }
            try writer.writeAll("            }\n        }\n");
        }

        try writer.writeAll("    }\n");
    }

    fn visitBinaryExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const bin = node.binary_expr;
        const left_node = self.tree.getNode(bin.left);

        if (bin.operator._type == .assign_token) {
            if (left_node == .identifier and std.mem.eql(u8, self.pool.get(left_node.identifier.name_id), "_")) {
                try writer.writeAll("(void)(");
                try self.visitNodeIndex(bin.right, writer);
                try writer.writeAll(")");
                return;
            }

            if (left_node == .index_expr) {
                try writer.writeAll("FLINT_SET_INDEX(");
                try self.visitNodeIndex(left_node.index_expr.left, writer);
                try writer.writeAll(", ");
                try self.visitNodeIndex(left_node.index_expr.index, writer);
                try writer.writeAll(", ");
                try self.visitNodeIndex(bin.right, writer);
                try writer.writeAll(")");
                return;
            }
        }

        if (bin.operator._type == .equal_token or bin.operator._type == .bang_equal_token) {
            const macro_name = if (bin.operator._type == .equal_token) "FLINT_EQ(" else "FLINT_NEQ(";
            try writer.writeAll(macro_name);
            try self.visitNodeIndex(bin.left, writer);
            try writer.writeAll(", ");
            try self.visitNodeIndex(bin.right, writer);
            try writer.writeAll(")");
            return;
        }

        try writer.writeAll("(");
        try self.visitNodeIndex(bin.left, writer);

        const op_str = switch (bin.operator._type) {
            .assign_token => " = ",
            .plus_token => " + ",
            .minus_token => " - ",
            .star_token => " * ",
            .remainder_token => " % ",
            .slash_token => " / ",
            .less_token => " < ",
            .greater_token => " > ",
            .less_equal_token => " <= ",
            .greater_equal_token => " >= ",
            .plus_equal_token => " += ",
            .minus_equal_token => " -= ",
            .star_equal_token => " *= ",
            .slash_equal_token => " /= ",
            .remainder_equal_token => " %= ",
            else => " ?? ",
        };

        try writer.writeAll(op_str);
        try self.visitNodeIndex(bin.right, writer);
        try writer.writeAll(")");
    }

    fn visitUnaryExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const un = node.unary_expr;
        const op_str = if (un.operator._type == .not_token) "!(" else "-(";
        try writer.writeAll(op_str);
        try self.visitNodeIndex(un.right, writer);
        try writer.writeAll(")");
    }

    fn visitLiteral(self: *CEmitter, node: AstNode, writer: anytype) !void {
        _ = self;
        const tok = node.literal.token;

        if (tok._type == .string_literal_token or tok._type == .multile_string_literal_token) {
            try writer.writeAll("FLINT_STR(\"");

            for (tok.value, 0..) |char, i| {
                switch (char) {
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => {},
                    '"' => {
                        if (i > 0 and tok.value[i - 1] == '\\') {
                            try writer.writeAll("\"");
                        } else {
                            try writer.writeAll("\\\"");
                        }
                    },
                    else => {
                        const str = [_]u8{char};
                        try writer.writeAll(&str);
                    },
                }
            }
            try writer.writeAll("\")");
        } else if (tok._type == .integer_literal_token or tok._type == .float_literal_token) {
            for (tok.value) |char| {
                if (char != '_') {
                    const str = [_]u8{char};
                    try writer.writeAll(&str);
                }
            }
        } else {
            try writer.writeAll(tok.value);
        }
    }

    fn visitCallExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const call = node.call_expr;
        const callee_node = self.tree.getNode(call.callee);

        if (callee_node == .identifier) {
            const func_name = self.pool.get(callee_node.identifier.name_id);

            if (std.mem.eql(u8, func_name, "print") and call.arguments.len == 0) {
                try writer.print("flint_print(FLINT_STR(\"\"))", .{});
                return;
            }

            if (std.mem.eql(u8, func_name, "int_array")) {
                try writer.writeAll("(flint_int_array){.items = NULL, .count = 0, .capacity = 0}");
                return;
            }
            if (std.mem.eql(u8, func_name, "str_array")) {
                try writer.writeAll("(flint_str_array){.items = NULL, .count = 0, .capacity = 0}");
                return;
            }
            if (std.mem.eql(u8, func_name, "bool_array")) {
                try writer.writeAll("(flint_bool_array){.items = NULL, .count = 0, .capacity = 0}");
                return;
            }

            if (std.mem.eql(u8, func_name, "to_str")) {
                try writer.writeAll("flint_to_str(FLINT_BOX(");
                try self.visitNodeIndex(call.arguments[0], writer);
                try writer.writeAll("))");
                return;
            }

            if (std.mem.eql(u8, func_name, "parse_json_as")) {
                if (call.arguments.len != 2) return error.InvalidArgumentCount;
                const struct_arg_node = self.tree.getNode(call.arguments[0]);
                const struct_name = self.pool.get(struct_arg_node.identifier.name_id);

                try writer.writeAll("__parse_");
                try writer.writeAll(struct_name);
                try writer.writeAll("_from_val(flint_parse_json(");
                try self.visitNodeIndex(call.arguments[1], writer);
                try writer.writeAll("))");
                return;
            }

            if (std.mem.eql(u8, func_name, "build_str")) {
                if (call.arguments.len == 0) {
                    try writer.writeAll("FLINT_STR(\"\")");
                    return;
                }
                if (call.arguments.len == 1) {
                    try self.visitNodeIndex(call.arguments[0], writer);
                    return;
                }

                if (self.is_run) {
                    const num_concats = call.arguments.len - 1;
                    for (0..num_concats) |_| {
                        try writer.writeAll("flint_concat(");
                    }

                    try self.visitNodeIndex(call.arguments[0], writer);

                    for (call.arguments[1..]) |arg| {
                        try writer.writeAll(", ");
                        try self.visitNodeIndex(arg, writer);
                        try writer.writeAll(")");
                    }
                } else {
                    try writer.writeAll("build_str(");
                    for (call.arguments, 0..) |arg, i| {
                        try self.visitNodeIndex(arg, writer);
                        if (i < call.arguments.len - 1) {
                            try writer.writeAll(", ");
                        }
                    }
                    try writer.writeAll(")");
                }
                return;
            }
        }

        try self.visitNodeIndex(call.callee, writer);
        try writer.writeAll("(");

        for (call.arguments, 0..) |arg_idx, i| {
            try self.visitNodeIndex(arg_idx, writer);
            if (i < call.arguments.len - 1) {
                try writer.writeAll(", ");
            }
        }
        try writer.writeAll(")");
    }

    fn visitArrayExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const arr = node.array_expr;

        if (arr.elements.len == 0) {
            try writer.writeAll("(flint_str_array){.items = NULL, .count = 0, .capacity = 0}");
            return;
        }

        const first_node = self.tree.getNode(arr.elements[0]);
        var c_type: []const u8 = "long long";
        var struct_name: []const u8 = "flint_int_array";

        if (first_node == .literal) {
            const tok = first_node.literal.token;
            if (tok._type == .string_literal_token or tok._type == .multile_string_literal_token) {
                c_type = "flint_str";
                struct_name = "flint_str_array";
            } else if (tok._type == .true_literal_token or tok._type == .false_literal_token) {
                c_type = "bool";
                struct_name = "flint_bool_array";
            }
        }

        self.temp_counter += 1;
        const t_id = self.temp_counter;

        try writer.writeAll("({\n");
        for (arr.elements, 0..) |el_idx, i| {
            try writer.print("        {s} _arr_el_{d}_{d} = ", .{ c_type, t_id, i });
            try self.visitNodeIndex(el_idx, writer);
            try writer.writeAll(";\n");
        }

        try writer.print("        FLINT_MAKE_ARRAY({s}, {s}, ", .{ c_type, struct_name });

        for (arr.elements, 0..) |_, i| {
            try writer.print("_arr_el_{d}_{d}", .{ t_id, i });
            if (i < arr.elements.len - 1) {
                try writer.writeAll(", ");
            }
        }

        try writer.writeAll(");\n    })");
    }

    fn visitIndexExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const index_node = self.tree.getNode(node.index_expr.index);

        if (index_node == .literal and index_node.literal.token._type == .string_literal_token) {
            const key_str = index_node.literal.token.value;
            const hash_val = computeFnv1aHash(key_str);

            try writer.writeAll("FLINT_GET_HASHED(");
            try self.visitNodeIndex(node.index_expr.left, writer);
            try writer.print(", \"{s}\", {d}ULL)", .{ key_str, hash_val });
        } else {
            try writer.writeAll("FLINT_INDEX(");
            try self.visitNodeIndex(node.index_expr.left, writer);
            try writer.writeAll(", ");
            try self.visitNodeIndex(node.index_expr.index, writer);
            try writer.writeAll(")");
        }
    }

    fn emitBoxedValue(self: *CEmitter, index: NodeIndex, writer: anytype) !void {
        const node = self.tree.getNode(index);
        if (node == .literal) {
            const tok = node.literal.token;
            if (tok._type == .string_literal_token or tok._type == .multile_string_literal_token) {
                try writer.writeAll("flint_make_str(");
                try self.visitNodeIndex(index, writer);
                try writer.writeAll(")");
            } else if (tok._type == .true_literal_token or tok._type == .false_literal_token) {
                try writer.writeAll("flint_make_bool(");
                try self.visitNodeIndex(index, writer);
                try writer.writeAll(")");
            } else if (tok._type == .float_literal_token) {
                try writer.writeAll("flint_make_float(");
                try self.visitNodeIndex(index, writer);
                try writer.writeAll(")");
            } else {
                try writer.writeAll("flint_make_int(");
                try self.visitNodeIndex(index, writer);
                try writer.writeAll(")");
            }
        } else {
            try writer.writeAll("flint_make_int(");
            try self.visitNodeIndex(index, writer);
            try writer.writeAll(")");
        }
    }

    fn visitCatchExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const catch_node = node.catch_expr;

        try writer.writeAll("({\n");
        try writer.writeAll("    FlintValue _catch_val = ");
        try self.visitNodeIndex(catch_node.expression, writer);
        try writer.writeAll(";\n");

        try writer.writeAll("    if (flint_is_err(_catch_val)) {\n");
        try writer.writeAll("        flint_str ");
        try writer.writeAll(self.pool.get(catch_node.error_identifier_id));
        try writer.writeAll(" = flint_get_err(_catch_val);\n");

        for (catch_node.body) |stmt_idx| {
            try writer.writeAll("        ");
            try self.visitNodeIndex(stmt_idx, writer);
            try writer.writeAll(";\n");
        }

        try writer.writeAll("    }\n");
        try writer.writeAll("    _catch_val;\n");
        try writer.writeAll("})");
    }

    fn visitDictExpr(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const dict = node.dict_expr;

        try writer.writeAll("({\n");

        const capacity = @max(16, dict.entries.len * 2);
        try writer.print("    FlintDict* _d = flint_dict_new({d});\n", .{capacity});

        for (dict.entries) |entry| {
            try writer.writeAll("    flint_dict_set(_d, ");
            try self.visitNodeIndex(entry.key, writer);
            try writer.writeAll(", ");

            try self.emitBoxedValue(entry.value, writer);
            try writer.writeAll(");\n");
        }

        try writer.writeAll("    (FlintValue){FLINT_VAL_DICT, .as.d = _d};\n");
        try writer.writeAll("})");
    }

    fn visitIdentifier(self: *CEmitter, node: AstNode, writer: anytype) !void {
        const name_str = self.pool.get(node.identifier.name_id);
        if (std.mem.eql(u8, name_str, "_")) {
            if (self.current_placeholder_name) |p| {
                try writer.writeAll(p);
                return;
            }
        }
        try self.writeMappedIdentifier(name_str, writer);
    }

    fn writeMappedIdentifier(self: *CEmitter, name: []const u8, writer: anytype) !void {
        if (std.mem.eql(u8, name, "get")) {
            try writer.writeAll("FLINT_GET");
            return;
        }

        if (std.mem.eql(u8, name, "set")) {
            try writer.writeAll("FLINT_SET");
            return;
        }

        for (self.built_ins) |built| {
            if (std.mem.eql(u8, built, name)) {
                try writer.writeAll("flint_");
                try writer.writeAll(name);
                return;
            }
        }

        try emitSafeName(writer, name);
    }

    fn emitSafeName(writer: anytype, name: []const u8) !void {
        const c_keywords = [_][]const u8{
            "auto",     "break",  "case",   "char",     "const",    "continue", "default",  "do",
            "double",   "else",   "enum",   "extern",   "float",    "for",      "goto",     "if",
            "inline",   "int",    "long",   "register", "restrict", "return",   "short",    "signed",
            "sizeof",   "static", "struct", "switch",   "typedef",  "union",    "unsigned", "void",
            "volatile", "while",  "printf", "malloc",   "free",     "exit",     "read",     "write",
            "open",     "close",  "main",   "stdin",    "stdout",   "stderr",   "math",     "sin",
            "cos",      "typeof",
        };

        for (c_keywords) |kw| {
            if (std.mem.eql(u8, name, kw)) {
                try writer.writeAll(name);
                try writer.writeAll("_");
                return;
            }
        }
        try writer.writeAll(name);
    }

    fn computeFnv1aHash(str: []const u8) u64 {
        var h: u64 = 1469598103934665603;
        for (str) |c| {
            h = (h ^ @as(u64, c)) *% 1099511628211;
        }
        return if (h == 0) 1 else h;
    }

    fn inferCType(self: *CEmitter, index: NodeIndex) ?[]const u8 {
        const node = self.tree.getNode(index);

        if (node == .call_expr) {
            const call = node.call_expr;
            const callee_node = self.tree.getNode(call.callee);

            if (callee_node == .identifier) {
                const func_name = self.pool.get(callee_node.identifier.name_id);

                if (std.mem.eql(u8, func_name, "parse_json_as")) {
                    if (call.arguments.len > 0) {
                        const struct_arg = self.tree.getNode(call.arguments[0]);
                        if (struct_arg == .identifier) {
                            return self.pool.get(struct_arg.identifier.name_id);
                        }
                    }
                }
            }
        }

        const flint_type = self.node_types.get(index) orelse return "FlintValue";

        return switch (flint_type) {
            .t_int => "long long",
            .t_string => "flint_str",
            .t_bool => "bool",
            .t_int_arr => "flint_int_array",
            .t_str_arr => "flint_str_array",
            .t_bool_arr => "flint_bool_array",
            .t_void => "void",
            .t_val => "FlintValue",
            .t_float => "double",
            else => "FlintValue",
        };
    }
};
