const std = @import("std");
const flint = @import("flint");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}).init;
    defer _ = gpa.deinit();

    const alloc = gpa.allocator();

    try flint.bufferedPrint(alloc);
}
