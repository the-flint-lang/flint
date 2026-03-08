const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;
const TokenType = @import("../lexer/enums/token_type.zig").TokenType;
const AstNode = @import("./ast.zig").AstNode;
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,

    arena: std.heap.ArenaAllocator,
    allocator: std.mem.Allocator,

    io: IoHelpers,
    had_error: bool = false,

    pub fn init(allocator: std.mem.Allocator, tokens: []const Token, io: IoHelpers) Parser {
        return .{
            .tokens = tokens,
            .current = 0,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .allocator = undefined, // preenchido pelo caller
            .io = io,
            .had_error = false,
        };
    }

    pub fn deinit(self: *Parser) void {
        self.arena.deinit();
    }

    pub fn parse(self: *Parser) anyerror!*AstNode {
        var statements: std.ArrayList(*AstNode) = .empty;

        while (!self.isAtEnd()) {
            const stmt = try self.parseDeclaration();
            try statements.append(self.allocator, stmt);
        }

        const program_node = try self.allocator.create(AstNode);
        program_node.* = .{
            .program = .{ .statements = try statements.toOwnedSlice(self.allocator) },
        };

        return program_node;
    }

    fn parseDeclaration(self: *Parser) anyerror!*AstNode {
        if (self.match(&.{.fn_token})) return self.parseFunctionDeclaration();
        if (self.match(&.{ .var_token, .const_token })) return self.parseVarDecl();

        return self.parseStatement();
    }

    fn parseIfStatement(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);

        const expr = try self.parseExpression();

        _ = try self.consume(.lbrace_token, "'{' expected before if block");
        const body = try self.parseBody();
        _ = try self.consume(.rbrace_token, "'}' expected to close if block");

        node.* = .{
            .if_stmt = .{
                .condition = expr,
                .then_branch = body,
            },
        };

        return node;
    }

    fn parseFunctionDeclaration(self: *Parser) anyerror!*AstNode {
        const node = try self.allocator.create(AstNode);

        const name = try self.consume(.identifier_token, "function name expected");

        _ = try self.consume(.lparen_token, "'(' expected after function name");
        const args = try self.parseArgs();
        _ = try self.consume(.rparen_token, "')' expected after function arguments");

        const return_type = self.advance();

        _ = try self.consume(.lbrace_token, "'{' expected before function body");
        const body = try self.parseBody();
        _ = try self.consume(.rbrace_token, "'}' expected to close function body");

        node.* = .{
            .function_decl = .{
                .name = name.value,
                .arguments = args,
                .return_type = return_type,
                .body = body,
            },
        };

        return node;
    }

    fn parseReturnStatement(self: *Parser) anyerror!*AstNode {
        return try self.parseExpressionStatement();
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

                // Shielding v1: Ensures that the called function is a valid name
                if (expr.* != .identifier) {
                    return self.reportError(self.previous(), "Invalid function call.");
                }

                const callee_name = expr.identifier.name;

                const node = try self.allocator.create(AstNode);
                node.* = .{ .call_expr = .{ .callee = callee_name, .arguments = try args.toOwnedSlice(self.allocator) } };
                expr = node;
            } else if (self.match(&.{.lbracket_token})) {
                const index_expr = try self.parseExpression();
                _ = try self.consume(.rbracket_token, "Expected ']' after index.");

                const node = try self.allocator.create(AstNode);
                node.* = .{ .index_expr = .{ .left = expr, .index = index_expr } };
                expr = node;
            } else {
                break;
            }
        }

        return expr;
    }

    fn parsePrimary(self: *Parser) anyerror!*AstNode {
        if (self.match(&.{ .false_literal_token, .true_literal_token, .integer_literal_token, .string_literal_token, .char_literal_token, .multile_string_literal_token })) {
            const node = try self.allocator.create(AstNode);
            node.* = .{ .literal = .{ .token = self.previous() } };
            return node;
        }

        if (self.match(&.{.identifier_token})) {
            const name_token = self.previous();
            const node = try self.allocator.create(AstNode);
            node.* = .{ .identifier = .{ ._type = name_token, .name = name_token.value } };
            return node;
        }

        if (self.match(&.{.lparen_token})) {
            const expr = try self.parseExpression();
            _ = try self.consume(.rparen_token, "Expected ')' after expression.");
            return expr;
        }

        if (self.match(&.{.lbracket_token})) {
            var elements = std.ArrayList(*AstNode).empty;

            // if array n is empty
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
        _ = try self.consume(.semicolon_token, "Expected ';' after expression.");
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
            if (!self.match(&.{ .integer_type_token, .string_type_token, .char_type_token, .boolean_type_token, .identifier_token })) {
                return self.reportError(self.peek(), "Invalid or unknown type.");
            }
        }

        _ = try self.consume(.assign_token, "Expected '=' after variable name.");

        const value_expr = try self.parseExpression();

        _ = try self.consume(.semicolon_token, "Expected ';' after variable declaration.");

        node.* = .{ .var_decl = .{
            ._type = null,
            .is_const = is_const,
            .name = name_token.value,
            .value = value_expr,
        } };

        return node;
    }

    fn parseExpression(self: *Parser) anyerror!*AstNode {
        return try self.parsePipeline();
    }

    fn parsePipeline(self: *Parser) anyerror!*AstNode {
        var expr = try self.parseEquality();

        while (self.match(&.{.pipeline_token})) {
            const right = try self.parseEquality();

            if (right.* != .call_expr) {
                return self.reportError(self.previous(), "O lado direito do operador de pipeline '~>' deve ser uma chamada de função.");
            }

            const node = try self.allocator.create(AstNode);
            node.* = .{ .pipeline_expr = .{
                .left = expr,
                .right_call = right,
            } };
            expr = node; // Encadeia da esquerda para a direita
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

    fn reportError(self: *Parser, token: Token, message: []const u8) anyerror!*AstNode {
        self.had_error = true;
        try self.io.stderr.print("[Line {d}] {s}\n", .{ token.line + 1, message });
        _ = try self.io.stderr.flush();

        return error.ParseError;
    }

    fn reportErrorT(self: *Parser, token: Token, message: []const u8) anyerror!Token {
        self.had_error = true;
        try self.io.stderr.print("[Line {d}] {s}\n", .{ token.line + 1, message });
        _ = try self.io.stderr.flush();

        return error.ParseError;
    }
};
