const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const TokenType = @import("../lexer/enums/token_type.zig").TokenType;
const AstNode = @import("./ast.zig").AstNode;
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;
const DictEntry = @import("./ast.zig").DictEntry;
const StructField = @import("./ast.zig").StructField;

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    source: []const u8,
    file_path: []const u8,

    allocator: std.mem.Allocator,

    io: IoHelpers,
    had_error: bool = false,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, source: []const u8, file_path: []const u8, io: IoHelpers) Parser {
        return .{
            .tokens = tokens,
            .source = source,
            .file_path = file_path,
            .current = 0,
            .allocator = allocator,
            .io = io,
            .had_error = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        _ = self;
    }

    pub fn parse(self: *Parser) anyerror!*AstNode {
        var statements: std.ArrayList(*AstNode) = .empty;

        while (!self.isAtEnd()) {
            if (self.parseDeclaration()) |stmt| {
                try statements.append(self.allocator, stmt);
            } else |err| {
                if (err == error.ParseError) {
                    self.synchronize();
                } else {
                    return err;
                }
            }
        }

        // if we had ANY errors during the process, we cannot generate a valid AST.
        // we return error here to prevent CEmitter from trying to generate broken code.
        if (self.had_error) return error.ParseError;

        const program_node = try self.allocator.create(AstNode);
        program_node.* = .{
            .program = .{ .statements = try statements.toOwnedSlice(self.allocator) },
        };

        return program_node;
    }

    fn parseDeclaration(self: *Parser) anyerror!*AstNode {
        if (self.match(&.{.import_token})) return self.parseImportStmt();
        if (self.match(&.{.struct_token})) return self.parseStructDecl();
        if (self.match(&.{ .fn_token, .extern_token })) return self.parseFunctionDeclaration();
        if (self.match(&.{ .var_token, .const_token })) return self.parseVarDecl();

        return self.parseStatement();
    }

    fn parseStructDecl(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);
        const name_token = try self.consume(.identifier_token, "Expected struct name.");

        _ = try self.consume(.lbrace_token, "Expected '{' before struct body.");

        var fields = std.ArrayList(*StructField).empty;

        if (!self.check(.rbrace_token)) {
            while (true) {
                const field_name = try self.consume(.identifier_token, "Expected field name.");
                _ = try self.consume(.colon_token, "Expected ':' after field name.");

                const field_type = self.advance();

                const field = try self.allocator.create(StructField);
                field.* = .{
                    .name = field_name.value,
                    ._type = field_type,
                };
                try fields.append(self.allocator, field);

                if (self.match(&.{.comma_token})) {
                    if (self.check(.rbrace_token)) break;
                } else {
                    break;
                }
            }
        }

        _ = try self.consume(.rbrace_token, "Expected '}' to close struct body.");

        node.* = .{ .struct_decl = .{
            .name = name_token.value,
            .fields = try fields.toOwnedSlice(self.allocator),
        } };

        return node;
    }

    fn parseImportStmt(self: *Parser) !*AstNode {
        var path: []const u8 = undefined;
        var alias: ?[]const u8 = null;

        if (self.match(&.{.string_literal_token})) {
            path = self.previous().value;
            if (self.match(&.{.as_token})) {
                _ = try self.consume(.identifier_token, "Expected alias name after 'as'.");
                alias = self.previous().value;
            }
        } else if (self.match(&.{.identifier_token})) {
            const mod_name = self.previous().value;
            path = mod_name;
            alias = mod_name;
        } else {
            return self.reportError(self.peek(), "Expected string path or module identifier after 'import'.");
        }

        _ = try self.consume(.semicolon_token, "Expected ';' after import statement.");

        const node = try self.allocator.create(AstNode);
        node.* = .{ .import_stmt = .{ .path = path, .alias = alias } };
        return node;
    }

    fn parseIfStatement(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);

        const expr = try self.parseExpression();

        _ = try self.consume(.lbrace_token, "'{' expected before if block");
        const body = try self.parseBody();
        _ = try self.consume(.rbrace_token, "'}' expected to close if block");

        var else_body: ?[]const *AstNode = null;

        if (self.match(&.{.else_token})) {
            _ = try self.consume(.lbrace_token, "'{' expected before else block");
            else_body = try self.parseBody();
            _ = try self.consume(.rbrace_token, "'}' expected to close else block");
        }

        node.* = .{
            .if_stmt = .{
                .condition = expr,
                .then_branch = body,
                .else_branch = else_body,
            },
        };

        return node;
    }

    fn parseFunctionDeclaration(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);

        const is_extern = self.previous()._type == .extern_token;

        if (is_extern) _ = try self.consume(.fn_token, "'fn' expected after extern");

        const name = try self.consume(.identifier_token, "function name expected");

        _ = try self.consume(.lparen_token, "'(' expected after function name");
        const args = try self.parseArgs();
        _ = try self.consume(.rparen_token, "')' expected after function arguments");

        const return_type = self.advance();

        var body: []const *AstNode = &.{};

        if (is_extern) {
            _ = try self.consume(.semicolon_token, "Expected ';' after extern function signature.");
        } else {
            _ = try self.consume(.lbrace_token, "'{' expected before function body");
            body = try self.parseBody();
            _ = try self.consume(.rbrace_token, "'}' expected to close function body");
        }

        node.* = .{
            .function_decl = .{
                .is_extern = is_extern,
                .name = name.value,
                .arguments = args,
                .return_type = return_type,
                .body = body,
            },
        };

        return node;
    }

    fn parseReturnStatement(self: *Parser) anyerror!*AstNode {
        var value: ?*AstNode = null;

        if (!self.check(.semicolon_token)) {
            value = try self.parseExpression();
        }

        _ = try self.consume(.semicolon_token, "Expected ';' after return value.");

        const node = try self.allocator.create(AstNode);
        node.* = .{ .return_stmt = .{ .value = value } };

        return node;
    }

    fn parseArgs(self: *Parser) ![]const *AstNode {
        var args: std.ArrayList(*AstNode) = .empty;

        if (!self.check(.rparen_token)) {
            while (true) {
                const name_token = try self.consume(.identifier_token, "argument name expected");
                _ = try self.consume(.colon_token, "expected ':' after argument name");
                const type_token = self.advance();

                const arg_node = try self.allocator.create(AstNode);
                arg_node.* = .{ .identifier = .{ ._type = type_token, .name = name_token.value } };
                try args.append(self.allocator, arg_node);

                if (!self.match(&.{.comma_token})) break;
            }
        }

        return try args.toOwnedSlice(self.allocator);
    }

    fn parseBody(self: *Parser) ![]const *AstNode {
        var statements: std.ArrayList(*AstNode) = .empty;

        while (!self.check(.rbrace_token) and !self.isAtEnd()) {
            const stmt = try self.parseDeclaration();
            try statements.append(self.allocator, stmt);
        }

        return try statements.toOwnedSlice(self.allocator);
    }

    fn parseUnary(self: *Parser) anyerror!*AstNode {
        if (self.match(&.{ .not_token, .minus_token })) {
            const operator = self.previous();
            const right = try self.parseUnary();

            const node = try self.allocator.create(AstNode);
            node.* = .{ .unary_expr = .{ .operator = operator, .right = right } };
            return node;
        }

        return try self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) anyerror!*AstNode {
        var expr = try self.parsePrimary();

        while (true) {
            if (self.match(&.{.lparen_token})) {
                var args: std.ArrayList(*AstNode) = .empty;
                if (!self.check(.rparen_token)) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpression());
                        if (!self.match(&.{.comma_token})) break;
                    }
                }

                _ = try self.consume(.rparen_token, "Expected ')' after arguments.");

                // Shielding the called function can be an identifier (print) or namespace property access (aws.apply)
                if (expr.* != .identifier and expr.* != .property_access_expr) {
                    return self.reportError(self.previous(), "Invalid function call.");
                }

                const node = try self.allocator.create(AstNode);
                node.* = .{
                    .call_expr = .{
                        .line = self.previous().line + 1,
                        .callee = expr,
                        .arguments = try args.toOwnedSlice(self.allocator),
                    },
                };
                expr = node;
            } else if (self.match(&.{.lbracket_token})) {
                const index_expr = try self.parseExpression();
                _ = try self.consume(.rbracket_token, "Expected ']' after index.");

                const node = try self.allocator.create(AstNode);
                node.* = .{ .index_expr = .{ .left = expr, .index = index_expr } };
                expr = node;
            } else if (self.match(&.{.dot_token})) {
                const property_token = try self.consume(.identifier_token, "Expected property name after '.'.");

                const node = try self.allocator.create(AstNode);
                node.* = .{ .property_access_expr = .{
                    .line = property_token.line + 1,
                    .object = expr,
                    .property_name = property_token.value,
                } };
                expr = node;
            } else {
                break;
            }
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) anyerror!*AstNode {
        if (self.match(&.{.interpolated_string_token})) {
            return try self.parseInterpolatedString(self.previous());
        }

        if (self.match(&.{ .false_literal_token, .true_literal_token, .integer_literal_token, .string_literal_token, .char_literal_token, .multile_string_literal_token })) {
            const node = try self.allocator.create(AstNode);
            node.* = .{ .literal = .{ .token = self.previous() } };
            return node;
        }

        if (self.match(&.{.identifier_token})) {
            const name_token = self.previous();
            const node = try self.allocator.create(AstNode);
            node.* = .{ .identifier = .{
                ._type = name_token,
                .name = name_token.value,
            } };
            return node;
        }

        if (self.match(&.{.lparen_token})) {
            const expr = try self.parseExpression();
            _ = try self.consume(.rparen_token, "Expected ')' after expression.");
            return expr;
        }

        if (self.match(&.{.lbracket_token})) {
            var elements = std.ArrayList(*AstNode).empty;

            // if array not is empty
            if (!self.check(.rbracket_token)) {
                while (true) {
                    try elements.append(self.allocator, try self.parseExpression());

                    if (!self.match(&.{.comma_token})) break;
                }
            }

            _ = try self.consume(.rbracket_token, "Expected ']' to close the array.");

            const node = try self.allocator.create(AstNode);
            node.* = .{
                .array_expr = .{
                    .elements = try elements.toOwnedSlice(self.allocator),
                },
            };

            return node;
        }

        if (self.match(&.{.lbrace_token})) {
            var entries = std.ArrayList(*DictEntry).empty;

            if (!self.check(.rbrace_token)) {
                while (true) {
                    const key_code = try self.parseExpression();
                    _ = try self.consume(.colon_token, "Expected ':' after the dictionary key.");
                    const val_node = try self.parseExpression();

                    const entry = try self.allocator.create(DictEntry);
                    entry.* = .{ .key = key_code, .value = val_node };
                    try entries.append(self.allocator, entry);

                    if (!self.match(&.{.comma_token})) break;
                }
            }

            _ = try self.consume(.rbrace_token, "Expected '}' to close the dictionary.");

            const node = try self.allocator.create(AstNode);
            node.* = .{
                .dict_expr = .{ .entries = try entries.toOwnedSlice(self.allocator) },
            };

            return node;
        }

        return self.reportError(self.peek(), "Invalid or unrecognized expression.");
    }

    fn parseStatement(self: *Parser) anyerror!*AstNode {
        if (self.match(&.{.if_token})) return self.parseIfStatement();
        if (self.match(&.{.for_token})) return self.parseForStatement();
        if (self.match(&.{.return_token})) return self.parseReturnStatement();

        return self.parseExpressionStatement();
    }

    fn parseExpressionStatement(self: *Parser) anyerror!*AstNode {
        const expr = try self.parseExpression();
        const last_token = self.previous(); // token right after the complete expression

        if (!self.check(.semicolon_token)) {
            return self.reportError(last_token, "Expected ';' after expression.");
        }
        _ = self.advance();

        return expr;
    }

    fn parseForStatement(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);

        const iterator_token = try self.consume(.identifier_token, "Expected iterator variable name after 'for'.");

        _ = try self.consume(.in_token, "Expected 'in' after iterator variable.");

        const iterable_expr = try self.parseExpression();

        _ = try self.consume(.lbrace_token, "Expected '{' before for block.");
        const body = try self.parseBody();
        _ = try self.consume(.rbrace_token, "Expected '}' to close for block.");

        node.* = .{ .for_stmt = .{
            .iterator_name = iterator_token.value,
            .iterable = iterable_expr,
            .body = body,
        } };

        return node;
    }

    fn parseVarDecl(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);

        const is_const = self.previous()._type == .const_token;

        const name_token = try self.consume(.identifier_token, "Expected variable name.");

        if (self.match(&.{.colon_token})) {
            if (!self.match(&.{ .integer_type_token, .string_type_token, .char_type_token, .boolean_type_token, .identifier_token, .value_type_token, .array_type_token })) {
                return self.reportError(self.peek(), "Invalid or unknown type.");
            }
        }

        _ = try self.consume(.assign_token, "Expected '=' after variable name.");

        const value_expr = try self.parseExpression();

        _ = try self.consume(.semicolon_token, "Expected ';' after variable declaration.");

        node.* = .{
            .var_decl = .{
                .line = name_token.line + 1,
                ._type = null,
                .is_const = is_const,
                .name = name_token.value,
                .value = value_expr,
            },
        };

        return node;
    }

    fn parseExpression(self: *Parser) anyerror!*AstNode {
        return try self.parseAssignment();
    }

    fn parseAssignment(self: *Parser) anyerror!*AstNode {
        const expr = try self.parsePipeline();

        if (self.match(&.{.catch_token})) {
            _ = try self.consume(.pipe_token, "Expected '|' after 'catch' keyword.");
            const err_token = try self.consume(.identifier_token, "Expected error variable name.");
            _ = try self.consume(.pipe_token, "Expected '|' to close the error variable.");

            _ = try self.consume(.lbrace_token, "Expected '{' to start the catch block.");

            var body = std.ArrayList(*AstNode).empty;
            while (!self.check(.rbrace_token) and !self.isAtEnd()) {
                const stmt = try self.parseStatement();
                try body.append(self.allocator, stmt);
            }

            _ = try self.consume(.rbrace_token, "Expected '}' to close the catch block.");

            const catch_node = try self.allocator.create(AstNode);
            catch_node.* = .{ .catch_expr = .{
                .expression = expr,
                .error_identifier = err_token.value,
                .body = try body.toOwnedSlice(self.allocator),
            } };

            return catch_node;
        }

        if (self.match(&.{.assign_token})) {
            const equals = self.previous();
            const value = try self.parseAssignment();

            if (expr.* == .identifier or expr.* == .index_expr or expr.* == .property_access_expr) {
                const node = try self.allocator.create(AstNode);
                node.* = .{ .binary_expr = .{ .left = expr, .operator = equals, .right = value } };
                return node;
            }

            return self.reportError(equals, "Invalid assignment target. You can only assign to variables, arrays or structs.");
        }

        return expr;
    }

    fn parsePipeline(self: *Parser) anyerror!*AstNode {
        var expr = try self.parseEquality();

        while (self.match(&.{.pipeline_token})) {
            const right = try self.parseEquality();

            if (right.* != .call_expr) {
                return self.reportError(self.previous(), "The right side of the '~>' pipeline operator must be a function call.");
            }

            const node = try self.allocator.create(AstNode);
            node.* = .{ .pipeline_expr = .{
                .left = expr,
                .right_call = right,
            } };
            expr = node; // Chain from left to right
        }

        return expr;
    }

    fn parseEquality(self: *Parser) anyerror!*AstNode {
        var expr = try self.parseComparison();

        while (self.match(&.{ .equal_token, .bang_equal_token })) {
            const operator = self.previous();
            const right = try self.parseComparison();

            const node = try self.allocator.create(AstNode);
            node.* = .{ .binary_expr = .{ .left = expr, .operator = operator, .right = right } };
            expr = node;
        }

        return expr;
    }

    fn parseComparison(self: *Parser) anyerror!*AstNode {
        var expr = try self.parseTerm();

        while (self.match(&.{ .less_token, .less_equal_token, .greater_token, .greater_equal_token })) {
            const operator = self.previous();
            const right = try self.parseTerm();

            const node = try self.allocator.create(AstNode);
            node.* = .{ .binary_expr = .{ .left = expr, .operator = operator, .right = right } };
            expr = node;
        }

        return expr;
    }

    fn parseTerm(self: *Parser) anyerror!*AstNode {
        var expr = try self.parseFactor();

        while (self.match(&.{ .plus_token, .minus_token })) {
            const operator = self.previous();
            const right = try self.parseFactor();

            const node = try self.allocator.create(AstNode);
            node.* = .{ .binary_expr = .{ .left = expr, .operator = operator, .right = right } };
            expr = node;
        }

        return expr;
    }

    fn parseFactor(self: *Parser) anyerror!*AstNode {
        var expr = try self.parseUnary();

        while (self.match(&.{ .star_token, .slash_token, .remainder_token })) {
            const operator = self.previous();
            const right = try self.parseUnary();

            const node = try self.allocator.create(AstNode);
            node.* = .{ .binary_expr = .{ .left = expr, .operator = operator, .right = right } };
            expr = node;
        }

        return expr;
    }

    fn peek(self: *Parser) Token {
        return self.tokens[self.current];
    }

    fn previous(self: *Parser) Token {
        return self.tokens[self.current - 1];
    }

    fn isAtEnd(self: *Parser) bool {
        return self.peek()._type == .eof_token;
    }

    fn advance(self: *Parser) Token {
        if (!self.isAtEnd()) self.current += 1;
        return self.previous();
    }

    fn match(self: *Parser, types: []const TokenType) bool {
        for (types) |t| {
            if (self.check(t)) {
                _ = self.advance();
                return true;
            }
        }

        return false;
    }

    fn check(self: *Parser, _type: TokenType) bool {
        if (self.isAtEnd()) return false;
        return self.peek()._type == _type;
    }

    fn consume(self: *Parser, _type: TokenType, message: []const u8) anyerror!Token {
        if (self.check(_type)) return self.advance();

        return self.reportErrorT(self.peek(), message);
    }

    fn printErrorContext(self: *Parser, token: Token, message: []const u8) anyerror!void {
        self.had_error = true;

        var lines = std.mem.splitScalar(u8, self.source, '\n');
        var current_line: u32 = 0;
        var target_line_text: []const u8 = "";

        while (lines.next()) |line| : (current_line += 1) {
            if (current_line == token.line) {
                target_line_text = line;
                break;
            }
        }

        const raw_len: u32 = switch (token._type) {
            .string_literal_token => @intCast(token.value.len + 2),
            .char_literal_token => @intCast(token.value.len + 2),
            .eof_token => 1,
            else => @intCast(if (token.value.len > 0) token.value.len else 1),
        };

        const token_len = raw_len;
        const start_col = if (token.column >= raw_len) token.column - raw_len else 0;

        const red = "\x1b[1;31m";
        const cyan = "\x1b[1;36m";
        const bold = "\x1b[1m";
        const reset = "\x1b[0m";

        try self.io.stderr.print("[{s}ERROR{s}]: {s}{s}{s}\n", .{ red, reset, bold, message, reset });

        try self.io.stderr.print("  {s}~~>{s} {s}:{d}:{d}\n", .{ cyan, reset, self.file_path, token.line + 1, start_col + 1 });

        try self.io.stderr.print("   {s}|{s}\n", .{ cyan, reset });

        try self.io.stderr.print("{d:2} {s}|{s} {s}\n", .{ token.line + 1, cyan, reset, target_line_text });

        try self.io.stderr.print("   {s}|{s} ", .{ cyan, reset });
        for (0..start_col) |_| try self.io.stderr.print(" ", .{});

        try self.io.stderr.print("{s}^{s}", .{ red, reset });
        if (token_len > 1) {
            for (1..token_len) |_| try self.io.stderr.print("{s}~{s}", .{ red, reset });
        }

        try self.io.stderr.print("\n   {s}|{s}\n\n", .{ cyan, reset });

        _ = try self.io.stderr.flush();
    }

    fn reportError(self: *Parser, token: Token, message: []const u8) anyerror!*AstNode {
        try self.printErrorContext(token, message);
        return error.ParseError;
    }

    fn reportErrorT(self: *Parser, token: Token, message: []const u8) anyerror!Token {
        try self.printErrorContext(token, message);
        return error.ParseError;
    }

    fn synchronize(self: *Parser) void {
        _ = self.advance();

        while (!self.isAtEnd()) {
            // if the previous token was a semicolon, the next line is probably safe
            if (self.previous()._type == .semicolon_token) return;

            switch (self.peek()._type) {
                .struct_token, .fn_token, .extern_token, .var_token, .const_token, .if_token, .for_token, .return_token => return,
                else => {},
            }

            _ = self.advance();
        }
    }

    fn createStringLiteralNode(self: *Parser, text: []const u8) !*AstNode {
        const node = try self.allocator.create(AstNode);
        node.* = .{ .literal = .{ .token = .{
            ._type = .string_literal_token,
            .value = text,
            .line = self.previous().line,
            .column = self.previous().column,
        } } };
        return node;
    }

    fn wrapInToStr(self: *Parser, expr: *AstNode) !*AstNode {
        const func_id = try self.allocator.create(AstNode);
        func_id.* = .{ .identifier = .{ ._type = Token{ ._type = .identifier_token, .value = "to_str", .line = 0, .column = 0 }, .name = "to_str" } };

        const call = try self.allocator.create(AstNode);
        var args = try self.allocator.alloc(*AstNode, 1);
        args[0] = expr;
        call.* = .{ .call_expr = .{ .line = 0, .callee = func_id, .arguments = args } };

        return call;
    }

    fn parseInterpolatedString(self: *Parser, token: Token) anyerror!*AstNode {
        var parts = std.ArrayList(*AstNode).empty;
        defer parts.deinit(self.allocator);

        const raw = token.value;
        var i: usize = 0;
        var start: usize = 0;
        var brace_depth: usize = 0;
        var in_expr = false;

        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (c == '\\') {
                i += 1;
                continue;
            }

            if (!in_expr) {
                if (c == '{') {
                    if (i > start) {
                        try parts.append(self.allocator, try self.createStringLiteralNode(raw[start..i]));
                    }
                    in_expr = true;
                    brace_depth = 1;
                    start = i + 1;
                }
            } else {
                if (c == '{') brace_depth += 1;
                if (c == '}') {
                    brace_depth -= 1;
                    if (brace_depth == 0) {
                        const expr_str = raw[start..i];

                        var sub_lexer = Lexer{
                            .alloc = self.allocator,
                            .io = self.io,
                            .position = 0,
                            .column = 0,
                            .line = token.line,
                            .source = expr_str,
                            .tokens = std.ArrayList(Token).empty,
                        };
                        const sub_tokens = try sub_lexer.tokenize();

                        var sub_parser = Parser.init(self.allocator, sub_tokens, expr_str, self.file_path, self.io);

                        const expr_node = try sub_parser.parseExpression();
                        try parts.append(self.allocator, try self.wrapInToStr(expr_node));

                        in_expr = false;
                        start = i + 1;
                    }
                }
            }
        }

        if (start < raw.len) {
            try parts.append(self.allocator, try self.createStringLiteralNode(raw[start..raw.len]));
        }

        if (parts.items.len == 0) return self.createStringLiteralNode("");

        const func_id = try self.allocator.create(AstNode);
        func_id.* = .{ .identifier = .{ ._type = Token{ ._type = .identifier_token, .value = "build_str", .line = 0, .column = 0 }, .name = "build_str" } };

        const call = try self.allocator.create(AstNode);
        call.* = .{ .call_expr = .{
            .line = token.line,
            .callee = func_id,
            .arguments = try parts.toOwnedSlice(self.allocator),
        } };

        return call;
    }
};
