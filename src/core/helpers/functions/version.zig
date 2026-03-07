const builtin = @import("build_options");

pub fn version(io: anytype) !void {
    try io.stdout.print("{s}\n", .{builtin.zemit_version});
    _ = io.stdout.flush() catch {};
}
