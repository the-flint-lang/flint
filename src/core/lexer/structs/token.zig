const std = @import("std");

const TokenType = @import("../enums/token_type.zig").TokenType;

pub const Token = struct {
    _type: TokenType,
    value: []const u8,

    line: u32,
    column: u32,

    pub fn toString(self: Token, alloc: std.mem.Allocator) ![]const u8 {
        if (self.value.len == 0) {
            return @tagName(self._type);
        }

        const r = try std.fmt.allocPrint(alloc, "{s}({s})", .{ @tagName(self._type), self.value });
        errdefer alloc.free(r);

        return r; // caller handles free
    }
};
