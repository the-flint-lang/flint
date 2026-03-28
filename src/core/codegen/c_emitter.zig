const std = @import("std");
const AstNode = @import("../parser/ast.zig").AstNode;
const TokenType = @import("../lexer/enums/token_type.zig").TokenType;
const Token = @import("../lexer/structs/token.zig").Token;

pub const CEmitter = struct {
    allocator: std.mem.Allocator,
    temp_counter: usize = 0,
    source_file: []const u8,

    built_ins: [15][]const u8,

    current_placeholder_name: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, source_file: []const u8) CEmitter {
        return .{
            .allocator = allocator,
            .source_file = source_file,
            .built_ins = [_][]const u8{
                "print",
                "printerr",
                "len",
                "push",
                "range",
                "if_fail",
                "fallback",
                "concat",
                "to_str",
                "to_int",
                "parse_json",
                "ensure",
                "lines",
                "grep",
                "chars",
            },
            .current_placeholder_name = null,
        };
    }

    pub fn generate(self: *CEmitter, writer: anytype, program: *AstNode) !void {
        try writer.print("#include \"flint_rt.h\"\n\n", .{});

        if (program.* == .program) {
            for (program.program.statements) |stmt| {
                switch (stmt.*) {
                    .function_decl => {
                        try self.visitFunctionDecl(stmt, writer);
                        try writer.print("\n", .{});
                    },

                    .struct_decl => {
                        try self.visitStructDecl(stmt, writer);
                        try writer.print("\n", .{});
                    },

                    else => {},
                }
            }
        }

        try writer.print("int main(int argc, char** argv) {{\n", .{});
        try writer.print("    flint_init(argc, argv);\n\n", .{});

        if (program.* == .program) {
            for (program.program.statements) |stmt| {
                if (stmt.* != .function_decl and stmt.* != .struct_decl) {
                    try writer.print("    ", .{});
                    try self.visitNode(stmt, writer);
                    try writer.print(";\n", .{});
                }
            }
        }

        try writer.print("\n    flint_deinit();\n", .{});
        try writer.print("    return 0;\n}}\n", .{});
    }

    fn containsPlaceholder(self: *CEmitter, node: *AstNode) bool {
        switch (node.*) {
            .identifier => return std.mem.eql(u8, node.identifier.name, "_"),
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

    fn visitFunctionDecl(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const func = node.function_decl;

        // if it is a native C function, the C Emitter does not need to generate the body,
        // because the Clang linker will tie this with flint_rt.c
        if (func.is_extern) return;

        const ret_type = switch (func.return_type._type) {
            .void_token => "void",
            .integer_type_token => "long long",
            .value_type_token => "FlintValue",
            .array_type_token => "flint_str_array",
            .boolean_type_token => "bool",

            else => "flint_str", // default fallback
        };

        try writer.print("{s} ", .{ret_type});
        try emitSafeName(writer, func.name);
        try writer.print("(", .{});

        for (func.arguments, 0..) |arg, i| {
            const arg_type_tok = arg.identifier._type._type;

            const c_type = switch (arg_type_tok) {
                .integer_type_token => "long long",
                .boolean_type_token => "bool",
                .value_type_token => "FlintValue",
                .array_type_token => "flint_str_array",
                else => "flint_str",
            };

            try writer.print("{s} ", .{c_type});
            try emitSafeName(writer, arg.identifier.name);

            if (i < func.arguments.len - 1) {
                try writer.print(", ", .{});
            }
        }

        try writer.print(") {{\n", .{});

        for (func.body) |stmt| {
            try writer.print("    ", .{});
            try self.visitNode(stmt, writer);
            try writer.print(";\n", .{});
        }

        try writer.print("}}\n", .{});
    }

    fn visitNode(self: *CEmitter, node: *AstNode, writer: anytype) anyerror!void {
        switch (node.*) {
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

            else => {
                std.debug.print("Codegen not implemented for: {s}\n", .{@tagName(node.*)});
                return error.NotImplemented;
            },
        }
    }

    fn visitReturnStmt(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        try writer.print("return", .{});

        if (node.return_stmt.value) |val| {
            try writer.print(" ", .{});
            try self.visitNode(val, writer);
        }
    }

    fn getCTypeFromToken(self: *CEmitter, token: Token) []const u8 {
        _ = self;
        return switch (token._type) {
            .string_type_token => "flint_str",
            .integer_type_token => "long long",
            .boolean_type_token => "bool",
            .value_type_token => "FlintValue",
            .array_type_token => "flint_str_array",
            .identifier_token => token.value,
            else => "void*",
        };
    }

    fn visitStructDecl(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const struct_node = node.struct_decl;

        try writer.print("typedef struct {{\n", .{});
        for (struct_node.fields) |field| {
            const c_type = self.getCTypeFromToken(field._type);
            try writer.print("    {s} ", .{c_type});
            try emitSafeName(writer, field.name);
            try writer.print(";\n", .{});
        }
        try writer.print("}} ", .{});
        try emitSafeName(writer, struct_node.name);
        try writer.print(";\n\n", .{});

        try writer.print("static ", .{});
        try emitSafeName(writer, struct_node.name);
        try writer.print(" __parse_{s}_from_val(FlintValue v_envelope) {{\n", .{struct_node.name});

        try writer.print("    FlintDict* d = (v_envelope.type == FLINT_VAL_DICT) ? v_envelope.as.d : NULL;\n", .{});

        try writer.print("    ", .{});
        try emitSafeName(writer, struct_node.name);
        try writer.print(" _obj;\n", .{});

        for (struct_node.fields) |field| {
            try writer.print("    FlintValue _v_{s} = d ? flint_dict_get(d, FLINT_STR(\"{s}\")) : (FlintValue){{FLINT_VAL_NULL}};\n", .{ field.name, field.name });

            try writer.print("    _obj.", .{});
            try emitSafeName(writer, field.name);

            if (field._type._type == .string_type_token) {
                try writer.print(" = (_v_{s}.type == FLINT_VAL_STR) ? _v_{s}.as.s : FLINT_STR(\"\");\n", .{ field.name, field.name });
            } else if (field._type._type == .integer_type_token) {
                try writer.print(" = (_v_{s}.type == FLINT_VAL_INT) ? _v_{s}.as.i : 0;\n", .{ field.name, field.name });
            } else if (field._type._type == .boolean_type_token) {
                try writer.print(" = (_v_{s}.type == FLINT_VAL_BOOL) ? _v_{s}.as.b : false;\n", .{ field.name, field.name });
            } else {
                try writer.print(" // TODO: Nested structs not mapped yet\n", .{});
            }
        }

        try writer.print("    return _obj;\n", .{});
        try writer.print("}}\n\n", .{});
    }

    fn visitPropertyAccessExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const prop_access = node.property_access_expr;
        try writer.print("\n        #line {d} \"{s}\"\n    ", .{ prop_access.line, self.source_file });

        try writer.print("(", .{});

        try self.visitNode(prop_access.object, writer);

        try writer.print(".{s}", .{prop_access.property_name});

        try writer.print(")", .{});
    }

    fn visitVarDecl(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const decl = node.var_decl;

        try writer.print("\n    #line {d} \"{s}\"\n    ", .{ decl.line, self.source_file });

        if (std.mem.eql(u8, decl.name, "_")) {
            try writer.print("(void)(", .{});
            try self.visitNode(decl.value, writer);
            try writer.print(")", .{});
            return;
        }

        if (decl.is_const) {
            try writer.print("const ", .{});
        }

        try writer.print("__auto_type ", .{});
        try emitSafeName(writer, decl.name);
        try writer.print(" = ", .{});
        try self.visitNode(decl.value, writer);
    }

    fn visitCallExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const call = node.call_expr;

        try writer.print("\n    #line {d} \"{s}\"\n    ", .{ call.line, self.source_file });

        if (call.callee.* == .identifier and std.mem.eql(u8, call.callee.identifier.name, "to_str")) {
            try writer.print("flint_to_str(FLINT_BOX(", .{});
            try self.visitNode(call.arguments[0], writer);
            try writer.print("))", .{});
            return;
        }

        if (call.callee.* == .identifier and std.mem.eql(u8, call.callee.identifier.name, "parse_json_as")) {
            if (call.arguments.len != 2) return error.InvalidArgumentCount;
            const struct_name = call.arguments[0].identifier.name;

            try writer.print("__parse_{s}_from_val(flint_parse_json(", .{struct_name});
            try self.visitNode(call.arguments[1], writer);
            try writer.print("))", .{});
            return;
        }

        try self.visitNode(call.callee, writer);
        try writer.print("(", .{});

        for (call.arguments, 0..) |arg, i| {
            try self.visitNode(arg, writer);
            if (i < call.arguments.len - 1) {
                try writer.print(", ", .{});
            }
        }
        try writer.print(")", .{});
    }

    fn visitPipelineExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const pipe = node.pipeline_expr;
        const right_call = pipe.right_call.call_expr;

        const has_placeholder = self.containsPlaceholder(pipe.right_call);

        if (has_placeholder) {
            self.temp_counter += 1;
            const temp_name = try std.fmt.allocPrint(self.allocator, "_pipe_val_{d}", .{self.temp_counter});
            defer self.allocator.free(temp_name);

            try writer.print("({{\n", .{});
            try writer.print("        __auto_type {s} = ", .{temp_name});
            try self.visitNode(pipe.left, writer);
            try writer.print(";\n", .{});

            const prev_placeholder = self.current_placeholder_name;
            self.current_placeholder_name = temp_name;

            try writer.print("        ", .{});
            try self.visitNode(pipe.right_call, writer);
            try writer.print(";\n", .{});

            self.current_placeholder_name = prev_placeholder;

            try writer.print("    }})", .{});
        } else {
            try self.visitNode(right_call.callee, writer);
            try writer.print("(", .{});

            try self.visitNode(pipe.left, writer);

            if (right_call.arguments.len > 0) {
                try writer.print(", ", .{});
                for (right_call.arguments, 0..) |arg, i| {
                    try self.visitNode(arg, writer);
                    if (i < right_call.arguments.len - 1) {
                        try writer.print(", ", .{});
                    }
                }
            }

            try writer.print(")", .{});
        }
    }

    fn visitIfStmt(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const if_node = node.if_stmt;

        try writer.print("if (", .{});
        try self.visitNode(if_node.condition, writer);
        try writer.print(") {{\n", .{});

        for (if_node.then_branch) |stmt| {
            try writer.print("        ", .{});
            try self.visitNode(stmt, writer);
            try writer.print(";\n", .{});
        }

        try writer.print("    }}", .{});

        if (if_node.else_branch) |else_body| {
            try writer.print(" else {{\n", .{});
            for (else_body) |stmt| {
                try writer.print("        ", .{});
                try self.visitNode(stmt, writer);
                try writer.print(";\n", .{});
            }
            try writer.print("    }}", .{});
        }
    }

    fn visitForStmt(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const for_node = node.for_stmt;
        self.temp_counter += 1;
        const iter_name = self.temp_counter;

        try writer.print("{{\n        __auto_type _iter_{d} = ", .{iter_name});
        try self.visitNode(for_node.iterable, writer);
        try writer.print(";\n", .{});

        try writer.print("        _Generic((_iter_{d}), \\\n", .{iter_name});

        try writer.print("            flint_int_array: ({{ \\\n", .{});
        try writer.print("                flint_int_array* _arr_{d} = (flint_int_array*)(void*)&_iter_{d}; \\\n", .{ iter_name, iter_name });
        try writer.print("                for (size_t _i_{d} = 0, _mark_{d} = flint_arena_mark(); _i_{d} < _arr_{d}->count; flint_arena_release(_mark_{d}), _mark_{d} = flint_arena_mark(), _i_{d}++) {{ \\\n", .{ iter_name, iter_name, iter_name, iter_name, iter_name, iter_name, iter_name });
        try writer.print("                    __auto_type {s} = _arr_{d}->items[_i_{d}]; \\\n", .{ for_node.iterator_name, iter_name, iter_name });
        for (for_node.body) |stmt| {
            try writer.print("                    ", .{});
            try self.visitNode(stmt, writer);
            try writer.print("; \\\n", .{});
        }
        try writer.print("                }} \\\n", .{});
        try writer.print("            }}), \\\n", .{});

        try writer.print("            flint_str_array: ({{ \\\n", .{});
        try writer.print("                flint_str_array* _arr_{d} = (flint_str_array*)(void*)&_iter_{d}; \\\n", .{ iter_name, iter_name });
        try writer.print("                for (size_t _i_{d} = 0, _mark_{d} = flint_arena_mark(); _i_{d} < _arr_{d}->count; flint_arena_release(_mark_{d}), _mark_{d} = flint_arena_mark(), _i_{d}++) {{ \\\n", .{ iter_name, iter_name, iter_name, iter_name, iter_name, iter_name, iter_name });
        try writer.print("                    __auto_type {s} = _arr_{d}->items[_i_{d}]; \\\n", .{ for_node.iterator_name, iter_name, iter_name });
        for (for_node.body) |stmt| {
            try writer.print("                    ", .{});
            try self.visitNode(stmt, writer);
            try writer.print("; \\\n", .{});
        }
        try writer.print("                }} \\\n", .{});
        try writer.print("            }}), \\\n", .{});

        try writer.print("            FlintValue: ({{ \\\n", .{});
        try writer.print("                FlintValue* _val_{d} = (FlintValue*)(void*)&_iter_{d}; \\\n", .{ iter_name, iter_name });
        try writer.print("                if (_val_{d}->type == FLINT_VAL_STREAM) {{ \\\n", .{iter_name});
        try writer.print("                    flint_stream* _stream_{d} = &_val_{d}->as.stream; \\\n", .{ iter_name, iter_name });

        try writer.print("                    for (size_t _mark_{d} = flint_arena_mark(); _stream_{d}->has_next; flint_arena_release(_mark_{d}), _mark_{d} = flint_arena_mark()) {{ \\\n", .{ iter_name, iter_name, iter_name, iter_name });
        try writer.print("                        __auto_type {s} = flint_stream_next(_stream_{d}); \\\n", .{ for_node.iterator_name, iter_name });
        for (for_node.body) |stmt| {
            try writer.print("                        ", .{});
            try self.visitNode(stmt, writer);
            try writer.print("; \\\n", .{});
        }
        try writer.print("                    }} \\\n", .{});
        try writer.print("                }} \\\n", .{});
        try writer.print("            }}) \\\n", .{});

        try writer.print("        );\n    }}", .{});
    }

    fn visitBinaryExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const bin = node.binary_expr;

        if (bin.operator._type == .assign_token) {
            if (bin.left.* == .identifier and std.mem.eql(u8, bin.left.identifier.name, "_")) {
                try writer.print("(void)(", .{});
                try self.visitNode(bin.right, writer);
                try writer.print(")", .{});
                return;
            }

            if (bin.left.* == .index_expr) {
                try writer.print("FLINT_SET_INDEX(", .{});
                try self.visitNode(bin.left.index_expr.left, writer); // array/dict
                try writer.print(", ", .{});
                try self.visitNode(bin.left.index_expr.index, writer); // índice
                try writer.print(", ", .{});
                try self.visitNode(bin.right, writer); // valor
                try writer.print(")", .{});
                return;
            }
        }

        if (bin.operator._type == .equal_token or bin.operator._type == .bang_equal_token) {
            const macro_name = if (bin.operator._type == .equal_token) "FLINT_EQ" else "FLINT_NEQ";

            try writer.print("{s}(", .{macro_name});
            try self.visitNode(bin.left, writer);
            try writer.print(", ", .{});
            try self.visitNode(bin.right, writer);
            try writer.print(")", .{});
            return;
        }

        try writer.print("(", .{});
        try self.visitNode(bin.left, writer);

        const op_str = switch (bin.operator._type) {
            .assign_token => "=",
            .plus_token => "+",
            .minus_token => "-",
            .star_token => "*",
            .remainder_token => "%",
            .slash_token => "/",
            .less_token => "<",
            .greater_token => ">",
            .less_equal_token => "<=",
            .greater_equal_token => ">=",
            else => " ?? ",
        };

        try writer.print(" {s} ", .{op_str});
        try self.visitNode(bin.right, writer);
        try writer.print(")", .{});
    }

    fn visitUnaryExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const un = node.unary_expr;
        const op_str = if (un.operator._type == .not_token) "!" else "-";
        try writer.print("{s}(", .{op_str});
        try self.visitNode(un.right, writer);
        try writer.print(")", .{});
    }

    fn visitLiteral(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        _ = self;
        const tok = node.literal.token;

        if (tok._type == .string_literal_token or tok._type == .multile_string_literal_token) {
            try writer.print("FLINT_STR(\"", .{});

            for (tok.value, 0..) |char, i| {
                switch (char) {
                    '\n' => try writer.print("\\n", .{}),
                    '\r' => {},
                    '"' => {
                        if (i > 0 and tok.value[i - 1] == '\\') {
                            try writer.print("\"", .{});
                        } else {
                            try writer.print("\\\"", .{});
                        }
                    },
                    else => try writer.print("{c}", .{char}),
                }
            }

            try writer.print("\")", .{});
        } else {
            // Números, true, false, null
            try writer.print("{s}", .{tok.value});
        }
    }

    fn visitArrayExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const arr = node.array_expr;

        if (arr.elements.len == 0) {
            std.debug.print("Error: Empty arrays not supported in v1.2 without explicit typing.\n", .{});
            return error.NotImplemented;
        }

        const first = arr.elements[0];
        var c_type: []const u8 = undefined;
        var struct_name: []const u8 = undefined;

        if (first.* == .literal) {
            const tok = first.literal.token;
            if (tok._type == .string_literal_token or tok._type == .multile_string_literal_token) {
                c_type = "flint_str";
                struct_name = "flint_str_array";
            } else if (tok._type == .true_literal_token or tok._type == .false_literal_token) {
                c_type = "bool";
                struct_name = "flint_bool_array";
            } else {
                c_type = "long long";
                struct_name = "flint_int_array";
            }
        }

        try writer.print("FLINT_MAKE_ARRAY({s}, {s}, ", .{ c_type, struct_name });

        for (arr.elements, 0..) |el, i| {
            try self.visitNode(el, writer);
            if (i < arr.elements.len - 1) {
                try writer.print(", ", .{});
            }
        }

        try writer.print(")", .{});
    }

    fn visitIndexExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const index_node = node.index_expr.index;

        if (index_node.* == .literal and index_node.literal.token._type == .string_literal_token) {
            const key_str = index_node.literal.token.value;
            const hash_val = computeFnv1aHash(key_str);

            try writer.print("FLINT_GET_HASHED(", .{});
            try self.visitNode(node.index_expr.left, writer);
            try writer.print(", \"{s}\", {d}ULL)", .{ key_str, hash_val });
        } else {
            try writer.print("FLINT_INDEX(", .{});
            try self.visitNode(node.index_expr.left, writer);
            try writer.print(", ", .{});
            try self.visitNode(index_node, writer);
            try writer.print(")", .{});
        }
    }

    fn emitBoxedValue(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        if (node.* == .literal) {
            const tok = node.literal.token;
            if (tok._type == .string_literal_token or tok._type == .multile_string_literal_token) {
                try writer.print("flint_make_str(", .{});
                try self.visitNode(node, writer);
                try writer.print(")", .{});
            } else if (tok._type == .true_literal_token or tok._type == .false_literal_token) {
                try writer.print("flint_make_bool(", .{});
                try self.visitNode(node, writer);
                try writer.print(")", .{});
            } else {
                try writer.print("flint_make_int(", .{});
                try self.visitNode(node, writer);
                try writer.print(")", .{});
            }
        } else {
            try writer.print("flint_make_int(", .{});
            try self.visitNode(node, writer);
            try writer.print(")", .{});
        }
    }

    fn visitCatchExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const catch_node = node.catch_expr;

        try writer.print("({{\n", .{});

        try writer.print("    FlintValue _catch_val = ", .{});
        try self.visitNode(catch_node.expression, writer);
        try writer.print(";\n", .{});

        try writer.print("    if (flint_is_err(_catch_val)) {{\n", .{});

        try writer.print("        flint_str {s} = flint_get_err(_catch_val);\n", .{catch_node.error_identifier});

        for (catch_node.body) |stmt| {
            try writer.print("        ", .{});
            try self.visitNode(stmt, writer);
            try writer.print(";\n", .{});
        }

        try writer.print("    }}\n", .{});

        try writer.print("    _catch_val;\n", .{});
        try writer.print("}})", .{});
    }

    fn visitDictExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const dict = node.dict_expr;

        try writer.print("({{\n", .{});

        const capacity = @max(16, dict.entries.len * 2);
        try writer.print("    FlintDict* _d = flint_dict_new({d});\n", .{capacity});

        for (dict.entries) |entry| {
            try writer.print("    flint_dict_set(_d, ", .{});
            try self.visitNode(entry.key, writer);
            try writer.print(", ", .{});

            try self.emitBoxedValue(entry.value, writer);
            try writer.print(");\n", .{});
        }

        try writer.print("    _d;\n", .{});
        try writer.print("}})", .{});
    }

    fn visitIdentifier(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        if (std.mem.eql(u8, node.identifier.name, "_")) {
            if (self.current_placeholder_name) |p_name| {
                try writer.print("{s}", .{p_name});
                return;
            }
        }
        try self.writeMappedIdentifier(node.identifier.name, writer);
    }

    fn writeMappedIdentifier(self: *CEmitter, name: []const u8, writer: anytype) !void {
        if (std.mem.eql(u8, name, "get")) {
            try writer.print("FLINT_GET", .{});
            return;
        }

        if (std.mem.eql(u8, name, "set")) {
            try writer.print("FLINT_SET", .{});
            return;
        }

        for (self.built_ins) |built| {
            if (std.mem.eql(u8, built, name)) {
                try writer.print("flint_{s}", .{name});
                return;
            }
        }

        try emitSafeName(writer, name);
    }

    fn emitSafeName(writer: anytype, name: []const u8) !void {
        const c_keywords = [_][]const u8{
            // C reserved words
            "auto",     "break",  "case",   "char",     "const",    "continue", "default",  "do",
            "double",   "else",   "enum",   "extern",   "float",    "for",      "goto",     "if",
            "inline",   "int",    "long",   "register", "restrict", "return",   "short",    "signed",
            "sizeof",   "static", "struct", "switch",   "typedef",  "union",    "unsigned", "void",
            "volatile", "while",

            // LibC/POSIX dangerous functions
             "printf", "malloc",   "free",     "exit",     "read",     "write",
            "open",     "close",  "main",   "stdin",    "stdout",   "stderr",   "math",     "sin",
            "cos",
        };

        for (c_keywords) |kw| {
            if (std.mem.eql(u8, name, kw)) {
                try writer.print("{s}_", .{name});
                return;
            }
        }

        try writer.print("{s}", .{name});
    }

    fn computeFnv1aHash(str: []const u8) u64 {
        var h: u64 = 1469598103934665603;
        for (str) |c| {
            // use *% to allow natural overflow without Zig panicking
            h = (h ^ @as(u64, c)) *% 1099511628211;
        }

        return if (h == 0) 1 else h;
    }
};
