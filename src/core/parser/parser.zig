const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;
const Lexer = @import("../lexer/lexer.zig").Lexer;
const TokenType = @import("../lexer/enums/token_type.zig").TokenType;
const ast = @import("./ast.zig");
const AstNode = ast.AstNode;
const AstTree = ast.AstTree;
const NodeIndex = ast.NodeIndex;
const DictEntry = ast.DictEntry;
const StructField = ast.StructField;
const StringPool = ast.StringPool;
const StringId = ast.StringId;
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;
const DiagnosticBuilder = @import("../errors/diagnostics.zig").DiagnosticBuilder;

pub const Parser = struct {
    tokens: []const Token,
    current: usize = 0,
    source: []const u8,
    file_path: []const u8,
    file_id: u32,

    allocator: std.mem.Allocator,
    tree: *AstTree,
    pool: *StringPool,

    io: IoHelpers,
    had_error: bool = false,
    disable_range: bool = false,

    pub fn init(allocator: std.mem.Allocator, tree: *AstTree, pool: *StringPool, tokens: []const Token, source: []const u8, file_path: []const u8, file_id: u32, io: IoHelpers) Parser {
        return .{
            .tokens = tokens,
            .source = source,
            .file_path = file_path,
            .file_id = file_id,
            .current = 0,
            .allocator = allocator,
            .tree = tree,
            .pool = pool,
            .io = io,
            .had_error = false,
        };
    }

    pub fn deinit(self: Parser) void {
        _ = self;
    }

    pub fn parse(self: *Parser) anyerror!NodeIndex {
        var statements = std.ArrayList(NodeIndex).empty;
        defer statements.deinit(self.allocator);

        while (!self.isAtEnd()) {
            if (self.parseDeclaration()) |stmt_idx| {
                try statements.append(self.allocator, stmt_idx);
            } else |err| {
                if (err == error.ParseError) {
                    self.synchronize();
                } else {
                    return err;
                }
            }
        }

        if (self.had_error) return error.ParseError;

        return try self.tree.addNode(self.allocator, .{
            .program = .{ .statements = try statements.toOwnedSlice(self.allocator) },
        });
    }

    fn parseDeclaration(self: *Parser) anyerror!NodeIndex {
        if (self.match(&.{.import_token})) return self.parseImportStmt();
        if (self.match(&.{.struct_token})) return self.parseStructDecl();
        if (self.match(&.{ .fn_token, .extern_token })) return self.parseFunctionDeclaration();
        if (self.match(&.{ .var_token, .const_token })) return self.parseVarDecl();

        return self.parseStatement();
    }

    fn parseStructDecl(self: *Parser) anyerror!NodeIndex {
        const name_token = try self.consume(.identifier_token, "Expected struct name.");
        const name_id = try self.pool.intern(self.allocator, name_token.value);

        _ = try self.consume(.lbrace_token, "Expected '{' before struct body.");

        var fields = std.ArrayList(StructField).empty;
        defer fields.deinit(self.allocator);

        if (!self.check(.rbrace_token)) {
            while (true) {
                const field_name = try self.consume(.identifier_token, "Expected field name.");
                _ = try self.consume(.colon_token, "Expected ':' after field name.");

                const field_type = self.advance();

                try fields.append(self.allocator, .{
                    .name_id = try self.pool.intern(self.allocator, field_name.value),
                    ._type = field_type,
                });

                if (self.match(&.{.comma_token})) {
                    if (self.check(.rbrace_token)) break;
                } else {
                    break;
                }
            }
        }

        _ = try self.consumeDelimiter(.rbrace_token, "Expected '}' to close struct body.");

        return try self.tree.addNode(self.allocator, .{
            .struct_decl = .{
                .line = name_token.line,
                .column = name_token.column,
                .file_id = name_token.file_id,
                .name_id = name_id,
                .fields = try fields.toOwnedSlice(self.allocator),
            },
        });
    }

    fn parseImportStmt(self: *Parser) !NodeIndex {
        var path: []const u8 = undefined;
        var alias_id: ?StringId = null;

        if (self.match(&.{.string_literal_token})) {
            path = self.previous().value;
            if (self.match(&.{.as_token})) {
                _ = try self.consume(.identifier_token, "Expected alias name after 'as'.");
                alias_id = try self.pool.intern(self.allocator, self.previous().value);
            }
        } else if (self.match(&.{.identifier_token})) {
            const mod_name = self.previous().value;
            path = mod_name;
            alias_id = try self.pool.intern(self.allocator, mod_name);
        } else {
            return self.reportError(self.peek(), "Expected string path or module identifier after 'import'.");
        }

        _ = try self.consume(.semicolon_token, "Expected ';' after import statement.");

        return try self.tree.addNode(self.allocator, .{ .import_stmt = .{ .path = path, .alias_id = alias_id } });
    }

    fn parseIfStatement(self: *Parser) anyerror!NodeIndex {
        const expr_idx = try self.parseExpression();

        _ = try self.consume(.lbrace_token, "'{' expected before if block");
        const body_indices = try self.parseBody();
        _ = try self.consumeDelimiter(.rbrace_token, "'}' expected to close if block");

        var else_body_indices: ?[]const NodeIndex = null;

        if (self.match(&.{.else_token})) {
            if (self.match(&.{.if_token})) {
                const else_if_idx = try self.parseIfStatement();
                var else_array = try self.allocator.alloc(NodeIndex, 1);
                else_array[0] = else_if_idx;
                else_body_indices = else_array;
            } else {
                _ = try self.consume(.lbrace_token, "'{' expected before else block");
                else_body_indices = try self.parseBody();
                _ = try self.consumeDelimiter(.rbrace_token, "'}' expected to close else block");
            }
        }

        return try self.tree.addNode(self.allocator, .{
            .if_stmt = .{
                .condition = expr_idx,
                .then_branch = body_indices,
                .else_branch = else_body_indices,
            },
        });
    }

    fn parseFunctionDeclaration(self: *Parser) anyerror!NodeIndex {
        const is_extern = self.previous()._type == .extern_token;

        if (is_extern) _ = try self.consume(.fn_token, "'fn' expected after extern");

        const name_token = try self.consume(.identifier_token, "function name expected");
        const name_id = try self.pool.intern(self.allocator, name_token.value);

        _ = try self.consume(.lparen_token, "'(' expected after function name");
        const args = try self.parseArgs();
        _ = try self.consumeDelimiter(.rparen_token, "')' expected after function arguments");

        const return_type = try self.parseType();

        var body: []const NodeIndex = &.{};

        if (is_extern) {
            _ = try self.consume(.semicolon_token, "Expected ';' after extern function signature.");
        } else {
            _ = try self.consume(.lbrace_token, "'{' expected before function body");
            body = try self.parseBody();
            _ = try self.consumeDelimiter(.rbrace_token, "'}' expected to close function body");
        }

        return try self.tree.addNode(self.allocator, .{
            .function_decl = .{
                .line = name_token.line,
                .column = name_token.column,
                .file_id = name_token.file_id,
                .is_extern = is_extern,
                .name_id = name_id,
                .arguments = args,
                .return_type = return_type,
                .body = body,
            },
        });
    }

    fn parseReturnStatement(self: *Parser) anyerror!NodeIndex {
        var value_idx: ?NodeIndex = null;

        if (!self.check(.semicolon_token)) {
            value_idx = try self.parseExpression();
        }

        _ = try self.consume(.semicolon_token, "Expected ';' after return value.");

        return try self.tree.addNode(self.allocator, .{ .return_stmt = .{ .value = value_idx } });
    }

    fn parseArgs(self: *Parser) ![]const NodeIndex {
        var args = std.ArrayList(NodeIndex).empty;
        defer args.deinit(self.allocator);

        if (!self.check(.rparen_token)) {
            while (true) {
                const name_token = try self.consume(.identifier_token, "argument name expected");
                _ = try self.consume(.colon_token, "expected ':' after argument name");
                const type_idx = try self.parseType();

                const arg_idx = try self.tree.addNode(self.allocator, .{ .param_decl = .{ .name_token = name_token, .type_node = type_idx } });
                try args.append(self.allocator, arg_idx);

                if (!self.match(&.{.comma_token})) break;
                if (self.check(.rbrace_token)) break;
            }
        }

        return try args.toOwnedSlice(self.allocator);
    }

    fn parseBody(self: *Parser) ![]const NodeIndex {
        var statements = std.ArrayList(NodeIndex).empty;
        defer statements.deinit(self.allocator);

        while (!self.check(.rbrace_token) and !self.isAtEnd()) {
            if (self.parseDeclaration()) |stmt_idx| {
                try statements.append(self.allocator, stmt_idx);
            } else |err| {
                if (err == error.ParseError) {
                    self.synchronize();
                } else {
                    return err;
                }
            }
        }

        return try statements.toOwnedSlice(self.allocator);
    }

    fn parseUnary(self: *Parser) anyerror!NodeIndex {
        if (self.match(&.{ .not_token, .minus_token })) {
            const operator = self.previous();
            const right_idx = try self.parseUnary();

            return try self.tree.addNode(self.allocator, .{ .unary_expr = .{ .operator = operator, .right = right_idx } });
        }

        return try self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parsePrimary();

        while (true) {
            if (self.match(&.{.lparen_token})) {
                var args = std.ArrayList(NodeIndex).empty;
                defer args.deinit(self.allocator);

                if (!self.check(.rparen_token)) {
                    while (true) {
                        try args.append(self.allocator, try self.parseExpression());
                        if (!self.match(&.{.comma_token})) break;
                    }
                }

                _ = try self.consumeDelimiter(.rparen_token, "Expected ')' after arguments.");

                const callee_node = self.tree.getNode(expr_idx);
                if (callee_node != .identifier and callee_node != .property_access_expr) {
                    return self.reportError(self.previous(), "Invalid function call.");
                }

                expr_idx = try self.tree.addNode(self.allocator, .{
                    .call_expr = .{
                        .line = self.previous().line,
                        .file_id = self.file_id,
                        .callee = expr_idx,
                        .arguments = try args.toOwnedSlice(self.allocator),
                    },
                });
            } else if (self.match(&.{.lbracket_token})) {
                var start_idx: ?NodeIndex = null;

                const prev_disable = self.disable_range;
                self.disable_range = true;

                if (!self.check(.rbracket_token) and !self.check(.dot_dot_token)) {
                    start_idx = self.parseExpression() catch |err| {
                        self.disable_range = prev_disable;
                        return err;
                    };
                }

                if (self.match(&.{.dot_dot_token})) {
                    var end_idx: ?NodeIndex = null;

                    if (!self.check(.rbracket_token)) {
                        end_idx = self.parseExpression() catch |err| {
                            self.disable_range = prev_disable;
                            return err;
                        };
                    }

                    self.disable_range = prev_disable;
                    _ = try self.consumeDelimiter(.rbracket_token, "Expected ']' after slice.");
                    expr_idx = try self.tree.addNode(self.allocator, .{ .slice_expr = .{ .left = expr_idx, .start = start_idx, .end = end_idx } });
                } else {
                    self.disable_range = prev_disable;
                    if (start_idx == null) {
                        return self.reportError(self.previous(), "Expected expression or '..' inside '[]'.");
                    }
                    _ = try self.consumeDelimiter(.rbracket_token, "Expected ']' after index.");
                    expr_idx = try self.tree.addNode(self.allocator, .{ .index_expr = .{ .left = expr_idx, .index = start_idx.? } });
                }
            } else if (self.match(&.{.dot_token})) {
                const property_token = try self.consume(.identifier_token, "Expected property name after '.'.");
                const prop_id = try self.pool.intern(self.allocator, property_token.value);

                expr_idx = try self.tree.addNode(self.allocator, .{ .property_access_expr = .{
                    .line = property_token.line,
                    .file_id = self.file_id,
                    .object = expr_idx,
                    .property_name_id = prop_id,
                } });
            } else {
                break;
            }
        }

        return expr_idx;
    }

    fn parsePrimary(self: *Parser) anyerror!NodeIndex {
        if (self.match(&.{.interpolated_string_token})) {
            return try self.parseInterpolatedString(self.previous());
        }

        if (self.match(&.{ .false_literal_token, .true_literal_token, .integer_literal_token, .float_literal_token, .string_literal_token, .char_literal_token, .multile_string_literal_token })) {
            return try self.tree.addNode(self.allocator, .{ .literal = .{ .token = self.previous() } });
        }

        if (self.match(&.{.identifier_token})) {
            const name_token = self.previous();
            const name_id = try self.pool.intern(self.allocator, name_token.value);
            return try self.tree.addNode(self.allocator, .{
                .identifier = .{
                    .token = name_token,
                    .name_id = name_id,
                },
            });
        }

        if (self.match(&.{.lparen_token})) {
            const expr_idx = try self.parseExpression();
            _ = try self.consumeDelimiter(.rparen_token, "Expected ')' after expression.");
            return expr_idx;
        }

        if (self.match(&.{.lbracket_token})) {
            var elements = std.ArrayList(NodeIndex).empty;
            defer elements.deinit(self.allocator);

            if (!self.check(.rbracket_token)) {
                while (true) {
                    try elements.append(self.allocator, try self.parseExpression());
                    if (!self.match(&.{.comma_token})) break;
                }
            }

            _ = try self.consumeDelimiter(.rbracket_token, "Expected ']' to close the array.");

            return try self.tree.addNode(self.allocator, .{
                .array_expr = .{
                    .elements = try elements.toOwnedSlice(self.allocator),
                },
            });
        }

        if (self.match(&.{.lbrace_token})) {
            var entries = std.ArrayList(DictEntry).empty;
            defer entries.deinit(self.allocator);

            if (!self.check(.rbrace_token)) {
                while (true) {
                    const key_idx = try self.parseExpression();
                    _ = try self.consume(.colon_token, "Expected ':' after the dictionary key.");
                    const val_idx = try self.parseExpression();

                    try entries.append(self.allocator, .{ .key = key_idx, .value = val_idx });

                    if (!self.match(&.{.comma_token})) break;
                    if (self.check(.rbrace_token)) break;
                }
            }

            _ = try self.consumeDelimiter(.rbrace_token, "Expected '}' to close the dictionary.");

            return try self.tree.addNode(self.allocator, .{
                .dict_expr = .{ .entries = try entries.toOwnedSlice(self.allocator) },
            });
        }

        return self.reportError(self.peek(), "Invalid or unrecognized expression.");
    }

    fn parseStatement(self: *Parser) anyerror!NodeIndex {
        if (self.match(&.{.if_token})) return self.parseIfStatement();
        if (self.match(&.{ .for_token, .stream_token })) return self.parseForStatement();
        if (self.match(&.{.return_token})) return self.parseReturnStatement();

        return self.parseExpressionStatement();
    }

    fn parseExpressionStatement(self: *Parser) anyerror!NodeIndex {
        const expr_idx = try self.parseExpression();
        const last_token = self.previous();

        if (!self.check(.semicolon_token)) {
            return self.reportSyntaxError(last_token, "E1001", "Expected ';' after expression", "expected `;`", true);
        }
        _ = self.advance();

        return expr_idx;
    }

    fn parseForStatement(self: *Parser) anyerror!NodeIndex {
        const is_stream = self.previous()._type == .stream_token;

        const iterator_token = try self.consume(.identifier_token, "Expected iterator variable name after 'for' or 'stream'.");
        const iter_id = try self.pool.intern(self.allocator, iterator_token.value);

        _ = try self.consume(.in_token, "Expected 'in' after iterator variable.");

        const iterable_expr_idx = try self.parseExpression();

        _ = try self.consume(.lbrace_token, "Expected '{' before block.");
        const body_indices = try self.parseBody();
        _ = try self.consumeDelimiter(.rbrace_token, "Expected '}' to close block.");

        return try self.tree.addNode(self.allocator, .{
            .for_stmt = .{
                .iterator_name_id = iter_id,
                .iterable = iterable_expr_idx,
                .body = body_indices,
                .is_stream = is_stream,
            },
        });
    }

    fn parseVarDecl(self: *Parser) anyerror!NodeIndex {
        const is_const = self.previous()._type == .const_token;

        const name_token = try self.consume(.identifier_token, "Expected variable name.");
        const name_id = try self.pool.intern(self.allocator, name_token.value);

        var type_node_idx: ?NodeIndex = null;

        if (self.match(&.{.colon_token})) {
            type_node_idx = try self.parseType();
        }

        _ = try self.consume(.assign_token, "Expected '=' after variable name.");

        const value_expr_idx = try self.parseExpression();

        _ = try self.consume(.semicolon_token, "Expected ';' after variable declaration.");

        return try self.tree.addNode(self.allocator, .{
            .var_decl = .{
                .line = name_token.line + 1,
                ._type = type_node_idx,
                .file_id = self.file_id,
                .is_const = is_const,
                .name_id = name_id,
                .value = value_expr_idx,
            },
        });
    }

    pub fn parseExpression(self: *Parser) !NodeIndex {
        return try self.parseAssignment();
    }

    fn parseLogicalOr(self: *Parser) !NodeIndex {
        var left = try self.parseLogicalAnd();
        while (self.match(&.{.or_token})) {
            const op_token = self.previous();
            const right = try self.parseLogicalAnd();
            left = try self.tree.addNode(self.allocator, .{ .logical_or = .{ .left = left, .operator = op_token, .right = right } });
        }
        return left;
    }

    fn parseLogicalAnd(self: *Parser) !NodeIndex {
        var left = try self.parseEquality();
        while (self.match(&.{.and_token})) {
            const op_token = self.previous();
            const right = try self.parseEquality();
            left = try self.tree.addNode(self.allocator, .{ .logical_and = .{ .left = left, .operator = op_token, .right = right } });
        }
        return left;
    }

    fn parseAssignment(self: *Parser) anyerror!NodeIndex {
        const expr_idx = try self.parsePipeline();

        if (self.match(&.{.catch_token})) {
            _ = try self.consume(.pipe_token, "Expected '|' after 'catch' keyword.");
            const err_token = try self.consume(.identifier_token, "Expected error variable name.");
            const err_id = try self.pool.intern(self.allocator, err_token.value);
            _ = try self.consume(.pipe_token, "Expected '|' to close the error variable.");

            _ = try self.consume(.lbrace_token, "Expected '{' to start the catch block.");

            var body = std.ArrayList(NodeIndex).empty;
            defer body.deinit(self.allocator);

            while (!self.check(.rbrace_token) and !self.isAtEnd()) {
                const stmt_idx = try self.parseStatement();
                try body.append(self.allocator, stmt_idx);
            }

            _ = try self.consumeDelimiter(.rbrace_token, "Expected '}' to close the catch block.");

            return try self.tree.addNode(self.allocator, .{ .catch_expr = .{
                .expression = expr_idx,
                .error_identifier_id = err_id,
                .body = try body.toOwnedSlice(self.allocator),
            } });
        }

        if (self.match(&.{.assign_token}) or
            self.match(&.{.plus_equal_token}) or
            self.match(&.{.minus_equal_token}) or
            self.match(&.{.star_equal_token}) or
            self.match(&.{.slash_equal_token}) or
            self.match(&.{.remainder_equal_token}))
        {
            const equals_token = self.previous();
            const value = try self.parseAssignment();

            const expr_node = self.tree.getNode(expr_idx);

            if (expr_node == .identifier or expr_node == .index_expr or expr_node == .property_access_expr) {
                return try self.tree.addNode(self.allocator, .{ .binary_expr = .{
                    .left = expr_idx,
                    .operator = equals_token,
                    .right = value,
                } });
            }

            return self.reportSyntaxError(equals_token, "E1004", "Invalid assignment target", "invalid assignment target", false);
        }

        return expr_idx;
    }

    fn parsePipeline(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parseLogicalOr();

        while (self.match(&.{.pipeline_token})) {
            const right_idx = try self.parseLogicalOr();

            const right_node = self.tree.getNode(right_idx);

            if (right_node != .call_expr) {
                return self.reportError(self.previous(), "The right side of the '~>' pipeline operator must be a function call.");
            }

            expr_idx = try self.tree.addNode(self.allocator, .{ .pipeline_expr = .{
                .left = expr_idx,
                .right_call = right_idx,
            } });
        }

        return expr_idx;
    }

    fn parseEquality(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parseComparison();

        while (self.match(&.{ .equal_token, .bang_equal_token })) {
            const operator = self.previous();
            const right_idx = try self.parseComparison();

            expr_idx = try self.tree.addNode(self.allocator, .{ .binary_expr = .{ .left = expr_idx, .operator = operator, .right = right_idx } });
        }

        return expr_idx;
    }

    fn parseComparison(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parseRange();

        while (self.match(&.{ .less_token, .less_equal_token, .greater_token, .greater_equal_token })) {
            const operator = self.previous();
            const right_idx = try self.parseRange();

            expr_idx = try self.tree.addNode(self.allocator, .{ .binary_expr = .{ .left = expr_idx, .operator = operator, .right = right_idx } });
        }

        return expr_idx;
    }

    fn parseType(self: *Parser) anyerror!NodeIndex {
        if (!self.match(&.{ .integer_type_token, .string_type_token, .char_type_token, .boolean_type_token, .value_type_token, .array_type_token, .identifier_token, .void_token })) {
            return self.reportError(self.peek(), "Expected type name.");
        }

        const base_token = self.previous();
        var inner_type_idx: ?NodeIndex = null;

        if (std.mem.eql(u8, base_token.value, "arr")) {
            if (self.match(&.{.less_token})) {
                inner_type_idx = try self.parseType();
                _ = try self.consume(.greater_token, "Expected '>' after generic type.");
            }
        }

        return try self.tree.addNode(self.allocator, .{ .type_expr = .{
            .base_token = base_token,
            .inner_type = inner_type_idx,
        } });
    }

    fn parseRange(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parseTerm();

        if (!self.disable_range and self.match(&.{.dot_dot_token})) {
            const line = self.previous().line;

            const right_idx = try self.parseTerm();

            // fake token
            const range_str_id = try self.pool.intern(self.allocator, "range");
            const range_callee = try self.tree.addNode(self.allocator, .{ .identifier = .{
                .token = Token{
                    ._type = .identifier_token,
                    .value = "range",
                    .line = line,
                    .file_id = self.file_id,
                    .column = 0,
                },
                .name_id = range_str_id,
            } });

            var args = std.ArrayList(NodeIndex).empty;
            try args.append(self.allocator, expr_idx);
            try args.append(self.allocator, right_idx);

            expr_idx = try self.tree.addNode(self.allocator, .{
                .call_expr = .{
                    .line = line,
                    .file_id = self.file_id,
                    .callee = range_callee,
                    .arguments = try args.toOwnedSlice(self.allocator),
                },
            });
        }

        return expr_idx;
    }

    fn parseTerm(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parseFactor();

        while (self.match(&.{ .plus_token, .minus_token })) {
            const operator = self.previous();
            const right_idx = try self.parseFactor();

            expr_idx = try self.tree.addNode(self.allocator, .{ .binary_expr = .{ .left = expr_idx, .operator = operator, .right = right_idx } });
        }

        return expr_idx;
    }

    fn parseFactor(self: *Parser) anyerror!NodeIndex {
        var expr_idx = try self.parseUnary();

        while (self.match(&.{ .star_token, .slash_token, .remainder_token })) {
            const operator = self.previous();
            const right_idx = try self.parseUnary();

            expr_idx = try self.tree.addNode(self.allocator, .{ .binary_expr = .{ .left = expr_idx, .operator = operator, .right = right_idx } });
        }

        return expr_idx;
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

    fn reportSyntaxError(self: *Parser, token: Token, code: []const u8, message: []const u8, label_text: []const u8, point_after: bool) anyerror!NodeIndex {
        self.had_error = true;
        var diag = DiagnosticBuilder.init(self.allocator, "SYNTAX ERROR", code, message, self.source, self.file_path);
        defer diag.deinit();

        var col = token.column;
        var len: u32 = if (token.value.len > 0) @intCast(token.value.len) else 1;

        if (point_after) {
            col += len;
            len = 1;
        }

        try diag.addLabel(token.line, col, len, label_text, true);
        try diag.emit(self.io);

        return error.ParseError;
    }

    fn reportSyntaxErrorT(self: *Parser, token: Token, code: []const u8, message: []const u8, label_text: []const u8, point_after: bool) anyerror!Token {
        _ = try self.reportSyntaxError(token, code, message, label_text, point_after);
        return error.ParseError;
    }

    fn reportError(self: *Parser, token: Token, message: []const u8) anyerror!NodeIndex {
        return self.reportSyntaxError(token, "E1003", message, "unexpected token", false);
    }

    fn reportErrorT(self: *Parser, token: Token, message: []const u8) anyerror!Token {
        return self.reportSyntaxErrorT(token, "E1003", message, "unexpected token", false);
    }

    fn consume(self: *Parser, _type: TokenType, message: []const u8) anyerror!Token {
        if (self.check(_type)) return self.advance();

        if (_type == .semicolon_token) {
            return self.reportSyntaxErrorT(self.previous(), "E1001", message, "expected `;`", false);
        }

        return self.reportSyntaxErrorT(self.peek(), "E1003", message, "unexpected token", false);
    }

    fn consumeDelimiter(self: *Parser, _type: TokenType, message: []const u8) anyerror!Token {
        if (self.check(_type)) return self.advance();

        return self.reportSyntaxErrorT(self.peek(), "E1002", message, "unclosed delimiter", false);
    }

    fn synchronize(self: *Parser) void {
        _ = self.advance();

        while (!self.isAtEnd()) {
            if (self.previous()._type == .semicolon_token) return;

            switch (self.peek()._type) {
                .struct_token, .fn_token, .extern_token, .var_token, .const_token, .if_token, .for_token, .return_token => return,
                else => {},
            }

            _ = self.advance();
        }
    }

    fn createStringLiteralNode(self: *Parser, text: []const u8) !NodeIndex {
        return try self.tree.addNode(self.allocator, .{ .literal = .{ .token = .{
            ._type = .string_literal_token,
            .value = text,
            .file_id = self.file_id,
            .line = self.previous().line,
            .column = self.previous().column,
        } } });
    }

    fn wrapInToStr(self: *Parser, expr_idx: NodeIndex) !NodeIndex {
        const to_str_id = try self.pool.intern(self.allocator, "to_str");
        const func_id_idx = try self.tree.addNode(self.allocator, .{ .identifier = .{ .token = Token{ ._type = .identifier_token, .value = "to_str", .line = 0, .column = 0, .file_id = self.file_id }, .name_id = to_str_id } });
        var args = try self.allocator.alloc(NodeIndex, 1);
        args[0] = expr_idx;

        return try self.tree.addNode(self.allocator, .{ .call_expr = .{ .line = 0, .callee = func_id_idx, .file_id = self.file_id, .arguments = args } });
    }

    fn parseInterpolatedString(self: *Parser, token: Token) anyerror!NodeIndex {
        var parts = std.ArrayList(NodeIndex).empty;
        defer parts.deinit(self.allocator);

        const raw = token.value;

        var content_visual_len: u32 = 0;
        var total_newlines: u32 = 0;
        for (raw) |byte| {
            if (byte == '\n') total_newlines += 1;
            if (byte < 0x80 or byte >= 0xC0) content_visual_len += 1;
        }

        var inner_start_col: u32 = 0;
        if (total_newlines == 0 and token.column > content_visual_len + 2) {
            inner_start_col = token.column - 2 - content_visual_len;
        }

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

                        var prefix_visual_len: u32 = 0;
                        for (raw[0..start]) |byte| {
                            if (byte < 0x80 or byte >= 0xC0) prefix_visual_len += 1;
                            if (byte == '\\') prefix_visual_len += 1;
                        }

                        var sub_lexer = Lexer{
                            .alloc = self.allocator,
                            .io = self.io,
                            .file_path = self.file_path,
                            .position = 0,
                            .column = inner_start_col + prefix_visual_len,
                            .line = token.line,
                            .file_id = self.file_id,
                            .source = expr_str,
                            .tokens = std.ArrayList(Token).empty,
                        };
                        const sub_tokens = try sub_lexer.tokenize();

                        var sub_parser_shared = Parser{
                            .allocator = self.allocator,
                            .tokens = sub_tokens,
                            .source = expr_str,
                            .file_path = self.file_path,
                            .current = 0,
                            .tree = self.tree,
                            .pool = self.pool,
                            .file_id = self.file_id,
                            .io = self.io,
                            .had_error = false,
                        };

                        const expr_idx = try sub_parser_shared.parseExpression();

                        try parts.append(self.allocator, try self.wrapInToStr(expr_idx));

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

        const build_str_id = try self.pool.intern(self.allocator, "build_str");
        const func_id_idx = try self.tree.addNode(self.allocator, .{
            .identifier = .{
                .token = Token{
                    ._type = .identifier_token,
                    .file_id = self.file_id,
                    .value = "build_str",
                    .line = token.line,
                    .column = token.column,
                },
                .name_id = build_str_id,
            },
        });

        return try self.tree.addNode(self.allocator, .{ .call_expr = .{
            .line = token.line,
            .file_id = self.file_id,
            .callee = func_id_idx,
            .arguments = try parts.toOwnedSlice(self.allocator),
        } });
    }
};
