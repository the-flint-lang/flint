const std = @import("std");

const Token = @import("./structs/token.zig").Token;
const TokenType = @import("./enums/token_type.zig").TokenType;
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;
const DiagnosticBuilder = @import("../errors/diagnostics.zig").DiagnosticBuilder;

const debugError = @import("../errors/diagnostics.zig").debugError;

const tokenMap = @import("./helpers/hasher.zig").tokenMap;

pub const Lexer = struct {
    position: u32,

    column: u32,
    line: u32,

    had_error: bool = false,

    source: []const u8,
    file_path: []const u8,
    tokens: std.ArrayList(Token),

    alloc: std.mem.Allocator,
    io: IoHelpers,

    fn reportError(self: *Lexer, code: []const u8, message: []const u8, line: u32, col: u32, len: u32, label_text: []const u8) !void {
        self.had_error = true;

        var diag = DiagnosticBuilder.init(self.alloc, "LEXICAL ERROR", code, message, self.source, self.file_path);
        defer diag.deinit();

        try diag.addLabel(line, col + len, len, label_text, true);
        try diag.emit(self.io);
    }

    pub fn tokenize(self: *Lexer) ![]const Token {
        try self.tokens.ensureTotalCapacity(self.alloc, self.source.len / 5);
        var c: u8 = 0;

        while (!self.isAtEnd()) {
            c = self.consume();

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
                const string = try self.readString();
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
                    const quote_char = self.consume();
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
                    if (self.match('=')) {
                        _type = .plus_equal_token;
                    } else {
                        _type = .plus_token;
                    }
                },

                '-' => {
                    if (self.match('=')) {
                        _type = .minus_equal_token;
                    } else {
                        _type = .minus_token;
                    }
                },

                '*' => {
                    if (self.match('=')) {
                        _type = .star_equal_token;
                    } else {
                        _type = .star_token;
                    }
                },

                '/' => {
                    if (self.match('=')) {
                        _type = .slash_equal_token;
                    } else {
                        _type = .slash_token;
                    }
                },

                '%' => {
                    if (self.match('=')) {
                        _type = .remainder_equal_token;
                    } else {
                        _type = .remainder_token;
                    }
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

                else => {
                    const start_pos = self.position - 1;
                    const start_col = self.column - 1;

                    while (!self.isAtEnd() and self.source[self.position] >= 128) {
                        self.advance();
                    }

                    const bad_slice = self.source[start_pos..self.position];

                    const visual_len = self.column - start_col;

                    const msg = try std.fmt.allocPrint(self.alloc, "invalid character: `{s}`", .{bad_slice});

                    try self.reportError("E0001", "Invalid character", self.line, start_col, visual_len, msg);
                    self.alloc.free(msg);

                    continue;
                },
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

        if (self.had_error) return error.LexicalError;
        return self.tokens.toOwnedSlice(self.alloc);
    }

    // lexer helpers
    fn readIdentifier(self: *Lexer) []const u8 {
        const init = self.position - 1;

        while (self.position < self.source.len) {
            const c = self.source[self.position];
            if (std.ascii.isAlphabetic(c) or c == '_' or std.ascii.isDigit(c)) {
                self.position += 1;
                self.column += 1;
            } else {
                break;
            }
        }

        return self.source[init..self.position];
    }

    fn readString(self: *Lexer) ![]const u8 {
        const start_col = self.column - 1;
        const init = self.position;

        while (!self.isAtEnd()) {
            const char = self.source[self.position];
            if (char == '"') break;

            if (char == '\\' and self.position + 1 < self.source.len) {
                self.advance();
            }
            self.advance();
        }

        if (self.isAtEnd()) {
            const visual_len = self.column - start_col;
            try self.reportError("E0002", "Unterminated string literal", self.line, start_col, visual_len, "string starts here but is never closed");
            return self.source[init..self.position];
        }

        self.advance();
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
        const start_col = self.column - 1;
        var dots: u8 = 0;

        while (!self.isAtEnd()) {
            const char = self.source[self.position];

            if (std.ascii.isDigit(char)) {
                self.advance();
            } else if (char == '.') {
                dots += 1;
                if (dots > 1) {
                    self.advance();
                    while (!self.isAtEnd() and std.ascii.isDigit(self.source[self.position])) {
                        self.advance();
                    }
                    const visual_len = self.column - start_col;
                    try self.reportError("E0003", "Invalid numeric literal", self.line, start_col, visual_len, "invalid number format (multiple decimals)");
                    break;
                }
                self.advance();
            } else if (std.ascii.isAlphabetic(char)) {
                self.advance();
                while (!self.isAtEnd() and std.ascii.isAlphanumeric(self.source[self.position])) {
                    self.advance();
                }
                const visual_len = self.column - start_col;
                try self.reportError("E0003", "Invalid numeric literal", self.line, start_col, visual_len, "invalid number format (letters are not allowed)");
                break;
            } else {
                break;
            }
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

    inline fn isAtEnd(self: *Lexer) bool {
        return self.position >= self.source.len;
    }

    inline fn consume(self: *Lexer) u8 {
        const ch = self.source[self.position];
        self.advance();
        return ch;
    }

    inline fn advance(self: *Lexer) void {
        const c = self.source[self.position];
        self.position += 1;

        if (c < 0x80 or c >= 0xC0) {
            self.column += 1;
        }
    }

    inline fn match(self: *Lexer, c: u8) bool {
        if (self.isAtEnd() or self.source[self.position] != c) return false;
        self.advance();
        return true;
    }

    inline fn peek(self: *Lexer, offset: u32) u8 {
        const index = self.position + offset;
        if (index >= self.source.len) return 0;
        return self.source[index];
    }
};
