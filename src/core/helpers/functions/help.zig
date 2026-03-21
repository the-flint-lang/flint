pub fn help(io: anytype) !void {
    const orange = "\x1b[38;5;208m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";
    const dim = "\x1b[2m";

    try io.stdout.print("{s}Usage:{s} flint <command> [options] <file.fl>\n\n", .{ bold, reset });

    try io.stdout.print("{s}Commands:{s}\n", .{ bold, reset });
    try io.stdout.print("  {s}{s}run{s}       Compile a .fl script and execute it in memory\n", .{ bold, orange, reset });
    try io.stdout.print("  {s}{s}build{s}     Compile a .fl script into a standalone native binary\n", .{ bold, orange, reset });
    try io.stdout.print("  {s}{s}test{s}      Run the test battery in the ./tests directory\n", .{ bold, orange, reset });

    try io.stdout.print("\n{s}Compiler Debug:{s}\n", .{ bold, reset });
    try io.stdout.print("  {s}lex{s}       Run the Lexer and print the Token stream\n", .{ dim, reset });
    try io.stdout.print("  {s}parse{s}     Run the Parser and validate the AST\n", .{ dim, reset });

    try io.stdout.print("\n{s}Global Options:{s}\n", .{ bold, reset });
    try io.stdout.print("  -h, --help     Show this help log\n", .{});
    try io.stdout.print("  -V, --version  Show the current Flint version\n", .{});
    try io.stdout.print("\n", .{});

    _ = try io.stdout.flush();
}
