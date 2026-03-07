const std = @import("std");
const flint = @import("flint");

pub fn main() !void {
    try flint.bufferedPrint();
}
