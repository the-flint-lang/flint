const std = @import("std");

pub fn cliArgsEquals(arg: []const u8, flags: []const []const u8) bool {
    for (flags) |flag| {
        if (std.mem.eql(u8, arg, flag)) {
            return true;
        }
    }
    return false;
}

pub fn strEquals(str_a: []const u8, str_b: []const u8) bool {
    return std.mem.eql(u8, str_a, str_b);
}
