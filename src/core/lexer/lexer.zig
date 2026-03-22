const std = @import("std");

const Token = @import("./structs/token.zig").Token;
const TokenType = @import("./enums/token_type.zig").TokenType;
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;

const debugError = @import("../errors/diagnostics.zig").debugError;

const tokenMap = @import("./helpers/hasher.zig").tokenMap;

pub const Lexer = struct {
    position: u32,

    column: u32,
    line: u32,

    source: []const u8,
    tokens: std.ArrayList(Token),

    alloc: std.mem.Allocator,
    io: IoHelpers,

    pub fn tokenize(self: *Lexer) ![]const Token {
        var c: u8 = 0;

        while (!self.isAtEnd()) {
            c = self.consume().?;

            if (c == '\n') {
                self.line += 1;
                self.column = 0;

                continue;
            }

            if (std.ascii.isWhitespace(c)) continue;

            if (c == '#') {
                while (!self.isAtEnd() and self.peek(0) != '\n') {
                    _ = self.consume();
                }
                continue;
            }

            if (std.ascii.isAlphabetic(c) or c == '_') {
                const indet = self.readIdentifier();

                const _type_ident = tokenMap.get(indet) orelse TokenType.identifier_token;

                try self.tokens.append(self.alloc, Token{
                    ._type = _type_ident,
                    .value = indet,
                    .column = self.column,
                    .line = self.line,
                });

                continue;
            }

            if (std.ascii.isDigit(c)) {
                const number = try self.readNumber();

                try self.tokens.append(self.alloc, Token{
                    ._type = .integer_literal_token,
                    .value = number,
                    .column = self.column,
                    .line = self.line,
                });

                continue;
            }

            if (c == '\"') {
                const string = self.readString();

                try self.tokens.append(self.alloc, Token{
                    ._type = .string_literal_token,
                    .value = string,
                    .column = self.column,
                    .line = self.line,
                });

                continue;
            }

            if (c == '\'') {
                const char = self.readChar();

                try self.tokens.append(self.alloc, Token{
                    ._type = .char_literal_token,
                    .value = char,
                    .column = self.column,
                    .line = self.line,
                });

                continue;
            }

            if (c == '`') {
                const string = self.readMultilineString();

                try self.tokens.append(self.alloc, Token{
                    ._type = .multile_string_literal_token,
                    .value = string,
                    .column = self.column,
                    .line = self.line,
                });

                continue;
            }

            if (c == '$') {
                if (!self.isAtEnd() and (self.peek(0) == '"' or self.peek(0) == '`')) {
                    const quote_char = self.consume().?;
                    const content = self.readInterpolatedString(quote_char);

                    try self.tokens.append(self.alloc, Token{
                        ._type = .interpolated_string_token,
                        .value = content,
                        .column = self.column,
                        .line = self.line,
                    });
                    continue;
                } else {
                    try self.tokens.append(self.alloc, Token{
                        ._type = .error_token,
                        .value = "$",
                        .column = self.column,
                        .line = self.line,
                    });
                    continue;
                }
            }

            var _type: TokenType = .init;

            switch (c) {
                '+' => {
                    _type = .plus_token;
                },

                '-' => {
                    _type = .minus_token;
                },

                '*' => {
                    _type = .star_token;
                },

                '/' => {
                    _type = .slash_token;
                },

                '%' => {
                    _type = .remainder_token;
                },

                ';' => {
                    _type = .semicolon_token;
                },

                '(' => {
                    _type = .lparen_token;
                },

                ')' => {
                    _type = .rparen_token;
                },

                '{' => {
                    _type = .lbrace_token;
                },

                '}' => {
                    _type = .rbrace_token;
                },

                '[' => {
                    _type = .lbracket_token;
                },

                ']' => {
                    _type = .rbracket_token;
                },

                ':' => {
                    _type = .colon_token;
                },

                ',' => {
                    _type = .comma_token;
                },

                '.' => {
                    _type = .dot_token;
                },

                '|' => {
                    _type = .pipe_token;
                },

                // multi-char
                '=' => {
                    if (self.match('=')) {
                        _type = .equal_token;
                    } else {
                        _type = .assign_token;
                    }
                },

                '!' => {
                    if (self.match('=')) {
                        _type = .bang_equal_token;
                    } else {
                        _type = .error_token;
                    }
                },

                '~' => {
                    if (self.match('>')) {
                        _type = .pipeline_token;
                    } else {
                        _type = .error_token;
                    }
                },

                '>' => {
                    if (self.match('=')) {
                        _type = .greater_equal_token;
                    } else {
                        _type = .greater_token;
                    }
                },

                '<' => {
                    if (self.match('=')) {
                        _type = .less_equal_token;
                    } else {
                        _type = .less_token;
                    }
                },

                else => _type = .error_token,
            }

            try self.tokens.append(self.alloc, Token{
                ._type = _type,
                .value = "",
                .column = self.column,
                .line = self.line,
            });
        }

        try self.tokens.append(self.alloc, Token{
            ._type = .eof_token,
            .value = "",
            .column = self.column,
            .line = self.line,
        });

        return self.tokens.toOwnedSlice(self.alloc);
    }

    // lexer helpers
    fn readIdentifier(self: *Lexer) []const u8 {
        const init = self.position - 1;

        while (!self.isAtEnd() and (std.ascii.isAlphabetic(self.source[self.position]) or self.source[self.position] == '_' or std.ascii.isDigit(self.source[self.position]))) {
            self.advance();
        }

        return self.source[init..self.position];
    }

    fn readString(self: *Lexer) []const u8 {
        const init = self.position;

        while (!self.isAtEnd()) {
            const char = self.source[self.position];

            if (char == '"') break;

            if (char == '\\' and self.position + 1 < self.source.len) {
                self.advance();
            }
            self.advance();
        }

        if (!self.isAtEnd()) self.advance();

        return self.source[init .. self.position - 1];
    }

    fn readInterpolatedString(self: *Lexer, quote: u8) []const u8 {
        const init = self.position;
        var brace_depth: i32 = 0;
        var in_inner_string: bool = false;
        var inner_string_quote: u8 = 0;

        while (!self.isAtEnd()) {
            const char = self.source[self.position];

            if (char == '\\') {
                self.advance();
                if (!self.isAtEnd()) self.advance();
                continue;
            }

            if (in_inner_string) {
                if (char == inner_string_quote) {
                    in_inner_string = false;
                }
            } else {
                if (char == '"' or char == '\'' or char == '`') {
                    if (char == quote and brace_depth == 0) {
                        break;
                    }

                    if (brace_depth > 0) {
                        in_inner_string = true;
                        inner_string_quote = char;
                    }
                } else if (char == '{') {
                    brace_depth += 1;
                } else if (char == '}') {
                    brace_depth -= 1;
                }
            }

            self.advance();
        }

        if (!self.isAtEnd()) self.advance();
        return self.source[init .. self.position - 1];
    }

    fn readMultilineString(self: *Lexer) []const u8 {
        const init = self.position;

        while (!self.isAtEnd() and self.source[self.position] != '`') {
            self.advance();
        }

        if (!self.isAtEnd()) self.advance();
        return self.source[init .. self.position - 1];
    }

    fn readNumber(self: *Lexer) ![]const u8 {
        const init = self.position - 1;

        while (!self.isAtEnd() and std.ascii.isDigit(self.source[self.position])) {
            self.advance();
        }

        if (!self.isAtEnd() and self.source[self.position] == '.') {
            self.advance();
            while (!self.isAtEnd() and std.ascii.isDigit(self.source[self.position])) {
                self.advance();
            }
            return self.source[init..self.position];
        }

        return self.source[init..self.position];
    }

    fn readChar(self: *Lexer) []const u8 {
        const init = self.position;
        var lenth: u8 = 0;

        while (!self.isAtEnd() and self.source[self.position] != '\'') {
            self.advance();
            lenth += 1;
        }

        // treat length tomorrow
        return self.source[init..self.position];
    }

    fn match(self: *Lexer, c: u8) bool {
        if (self.isAtEnd()) return false;
        if (self.source[self.position] != c) return false;

        self.position += 1;
        self.column += 1;
        return true;
    }

    fn isAtEnd(self: *Lexer) bool {
        return self.position >= self.source.len;
    }

    fn consume(self: *Lexer) ?u8 {
        if (self.isAtEnd()) return null;
        const ch = self.source[self.position];
        self.advance();
        return ch;
    }

    fn advance(self: *Lexer) void {
        if (!self.isAtEnd()) {
            self.position += 1;
            self.column += 1;
        }
    }

    fn peek(self: Lexer, offset: u8) u8 {
        const index = self.position + offset;

        if (index >= self.source.len) return '#';

        return self.source[index];
    }
};
