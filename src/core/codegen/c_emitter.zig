const std = @import("std");
const AstNode = @import("../parser/ast.zig").AstNode;
const TokenType = @import("../lexer/enums/token_type.zig").TokenType;
const Token = @import("../lexer/structs/token.zig").Token;

pub const CEmitter = struct {
    allocator: std.mem.Allocator,
    temp_counter: usize = 0,
    source_file: []const u8,

    pub fn init(allocator: std.mem.Allocator, source_file: []const u8) CEmitter {
        return .{ .allocator = allocator, .source_file = source_file };
    }

    pub fn generate(self: *CEmitter, writer: anytype, program: *AstNode) !void {
        try writer.print("#include \"flint_rt.h\"\n\n", .{});

        if (program.* == .program) {
            for (program.program.statements) |stmt| {
                if (stmt.* == .function_decl) {
                    try self.visitFunctionDecl(stmt, writer);
                    try writer.print("\n", .{});
                } else if (stmt.* == .struct_decl) {
                    try self.visitStructDecl(stmt, writer);
                    try writer.print("\n", .{});
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

    fn visitFunctionDecl(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const func = node.function_decl;

        const ret_type = switch (func.return_type._type) {
            .void_token => "void",
            .integer_type_token => "long long",
            .boolean_type_token => "bool",
            else => "flint_str", // Default fallback
        };

        try writer.print("{s} {s}(", .{ ret_type, func.name });

        for (func.arguments, 0..) |arg, i| {
            const arg_type_tok = arg.identifier._type._type;

            const c_type = switch (arg_type_tok) {
                .integer_type_token => "long long",
                .boolean_type_token => "bool",
                else => "flint_str",
            };

            try writer.print("{s} {s}", .{ c_type, arg.identifier.name });

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
            .property_access_expr => try self.visitPropertyAccessExpr(node, writer),

            else => {
                std.debug.print("Codegen not implemented for: {s}\n", .{@tagName(node.*)});
                return error.NotImplemented;
            },
        }
    }

    fn getCTypeFromToken(self: *CEmitter, token: Token) []const u8 {
        _ = self;
        return switch (token._type) {
            .string_type_token => "flint_str",
            .integer_type_token => "long long",
            .boolean_type_token => "bool",
            .identifier_token => token.value,
            else => "void*",
        };
    }

    fn visitStructDecl(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const struct_node = node.struct_decl;

        try writer.print("typedef struct {{\n", .{});
        for (struct_node.fields) |field| {
            const c_type = self.getCTypeFromToken(field._type);
            try writer.print("    {s} {s};\n", .{ c_type, field.name });
        }
        try writer.print("}} {s};\n\n", .{struct_node.name});

        try writer.print("static {s} __parse_{s}_from_dict(FlintDict* d) {{\n", .{ struct_node.name, struct_node.name });
        try writer.print("    {s} _obj;\n", .{struct_node.name});

        for (struct_node.fields) |field| {
            try writer.print("    FlintValue _v_{s} = flint_dict_get(d, FLINT_STR(\"{s}\"));\n", .{ field.name, field.name });

            if (field._type._type == .string_type_token) {
                try writer.print("    _obj.{s} = (_v_{s}.type == FLINT_VAL_STR) ? _v_{s}.as.s : FLINT_STR(\"\");\n", .{ field.name, field.name, field.name });
            } else if (field._type._type == .integer_type_token) {
                try writer.print("    _obj.{s} = (_v_{s}.type == FLINT_VAL_INT) ? _v_{s}.as.i : 0;\n", .{ field.name, field.name, field.name });
            } else if (field._type._type == .boolean_type_token) {
                try writer.print("    _obj.{s} = (_v_{s}.type == FLINT_VAL_BOOL) ? _v_{s}.as.b : false;\n", .{ field.name, field.name, field.name });
            } else {
                try writer.print("    // TODO: Nested structs not mapped yet\n", .{});
            }
        }

        try writer.print("    return _obj;\n", .{});
        try writer.print("}}\n\n", .{});
    }

    fn visitPropertyAccessExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const prop_access = node.property_access_expr;
        try writer.print("\n#line {d} \"{s}\"\n    ", .{ prop_access.line, self.source_file });

        try writer.print("(", .{});

        try self.visitNode(prop_access.object, writer);

        try writer.print(".{s}", .{prop_access.property_name});

        try writer.print(")", .{});
    }

    fn visitVarDecl(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const decl = node.var_decl;

        try writer.print("\n#line {d} \"{s}\"\n    ", .{ decl.line, self.source_file });

        if (std.mem.eql(u8, decl.name, "_")) {
            try writer.print("(void)(", .{});
            try self.visitNode(decl.value, writer);
            try writer.print(")", .{});
            return;
        }

        if (decl.is_const) {
            try writer.print("const ", .{});
        }

        try writer.print("__auto_type {s} = ", .{decl.name});
        try self.visitNode(decl.value, writer);
    }

    fn visitCallExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const call = node.call_expr;

        try writer.print("\n#line {d} \"{s}\"\n    ", .{ call.line, self.source_file });

        if (std.mem.eql(u8, call.callee, "parse_json_as")) {
            if (call.arguments.len != 2) return error.InvalidArgumentCount;

            const struct_name = call.arguments[0].identifier.name;

            try writer.print("__parse_{s}_from_dict(flint_parse_json(", .{struct_name});
            try self.visitNode(call.arguments[1], writer);
            try writer.print("))", .{});
            return;
        }

        try self.writeMappedIdentifier(call.callee, writer);
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

        try self.writeMappedIdentifier(right_call.callee, writer);
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

        try writer.print("{{\n        __auto_type _arr_{d} = ", .{iter_name});
        try self.visitNode(for_node.iterable, writer);
        try writer.print(";\n", .{});

        try writer.print("        for (size_t _i_{d} = 0; _i_{d} < _arr_{d}.count; _i_{d}++) {{\n", .{ iter_name, iter_name, iter_name, iter_name });

        try writer.print("            __auto_type {s} = _arr_{d}.items[_i_{d}];\n", .{ for_node.iterator_name, iter_name, iter_name });

        for (for_node.body) |stmt| {
            try writer.print("            ", .{});
            try self.visitNode(stmt, writer);
            try writer.print(";\n", .{});
        }

        try writer.print("        }}\n    }}", .{});
    }

    fn visitBinaryExpr(self: *CEmitter, node: *AstNode, writer: anytype) !void {
        const bin = node.binary_expr;

        if (bin.operator._type == .assign_token and bin.left.* == .identifier) {
            if (std.mem.eql(u8, bin.left.identifier.name, "_")) {
                try writer.print("(void)(", .{});
                try self.visitNode(bin.right, writer);
                try writer.print(")", .{});
                return;
            }
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
            .equal_token => "==",
            .bang_equal_token => "!=",
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

        if (tok._type == .string_literal_token) {
            try writer.print("FLINT_STR(\"{s}\")", .{tok.value});
        } else if (tok._type == .multile_string_literal_token) {
            try writer.print("\"", .{});

            for (tok.value) |char| {
                if (char == '\n') {
                    try writer.print("\\n", .{});
                } else if (char == '\r') {} else if (char == '"') {
                    try writer.print("\\\"", .{});
                } else {
                    try writer.print("{c}", .{char});
                }
            }

            try writer.print("\"", .{});
        } else {
            try writer.print("{s}", .{tok.value}); // Numbers, true, false
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
        const idx = node.index_expr;

        try self.visitNode(idx.left, writer);

        try writer.print(".items[", .{});

        try self.visitNode(idx.index, writer);

        try writer.print("]", .{});
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
        try self.writeMappedIdentifier(node.identifier.name, writer);
    }

    fn writeMappedIdentifier(self: *CEmitter, name: []const u8, writer: anytype) !void {
        _ = self;

        if (std.mem.eql(u8, name, "get")) {
            try writer.print("FLINT_GET", .{});
            return;
        }

        if (std.mem.eql(u8, name, "set")) {
            try writer.print("FLINT_SET", .{});
            return;
        }

        const stdlibs = [_][]const u8{
            // string
            "grep",
            "join",
            "trim",
            "split",
            "replace",
            "concat",
            "count_matches",
            "to_str",
            "int_to_str",

            // utils
            "to_int",

            // arays
            "lines",
            "args",
            "len",
            "range",
            "push",

            // i/o
            "print",
            "exec",
            "spawn",

            // filesystem
            "read_file",
            "write_file",
            "file_exists",
            "mkdir",
            "rm",
            "mv",
            "copy",
            "rm_dir",
            "touch",
            "ls",
            "is_dir",
            "is_file",
            "file_size",

            // user space
            "env",
            "exit",

            // http
            "fetch",
            "parse_json",

            // errors
            "is_err",
            "get_err",
        };

        for (stdlibs) |lib| {
            if (std.mem.eql(u8, name, lib)) {
                try writer.print("flint_{s}", .{name});
                return;
            }
        }
        try writer.print("{s}", .{name});
    }
};
