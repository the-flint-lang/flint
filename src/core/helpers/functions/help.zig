pub fn help(io: anytype) !void {
    io.stdout.print("Usage: flint [global options] <command> [command options]\n\n", .{}) catch {};
    io.stdout.print("Available commands\n", .{}) catch {};

    // debug command
    io.stdout.print("    lex:                Lex a .flt file.\n", .{}) catch {};
    io.stdout.print("    parse:              Parse a .flt file.\n", .{}) catch {};

    io.stdout.print("    build:              Compiles a .flt file.\n\n", .{}) catch {};

    io.stdout.print("General Commands\n", .{}) catch {};
    io.stdout.print("    -h, --help:         Show this help log.\n", .{}) catch {};
    io.stdout.print("    -V, --version:      Show flint version.\n", .{}) catch {};

    _ = try io.stdout.flush();
}
