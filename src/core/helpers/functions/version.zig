const builtin = @import("build_options");

pub fn version(io: anytype) !void {
    const orange = "\x1b[38;5;208m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try io.stdout.print("{s}{s}Flint{s} v{s}\n", .{ bold, orange, reset, builtin.flint_version });
    _ = io.stdout.flush() catch {};
}
