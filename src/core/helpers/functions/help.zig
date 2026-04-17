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

pub fn helpBuild(io: anytype) !void {
    const orange = "\x1b[38;5;208m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try io.stdout.print("{s}Usage:{s} flint {s}build{s} [options] <file.fl>\n\n", .{ bold, reset, orange, reset });
    try io.stdout.print("Compiles a .fl script into a standalone, dependency-free native binary.\n\n", .{});

    try io.stdout.print("{s}Build Options:{s}\n", .{ bold, reset });
    try io.stdout.print("  -o, --output <name>    Set the output binary name (default: file name).\n", .{});
    try io.stdout.print("  -c, --cpu <arch>       Target CPU architecture (baseline, x86_64, aarch).\n", .{});
    try io.stdout.print("  -s, --small            Optimize binary for size (-Os).\n", .{});

    try io.stdout.print("\n{s}Memory Options:{s}\n", .{ bold, reset });
    try io.stdout.print("  --arena-size <size>    Max capacity for the Arena Allocator (default: 4GB).\n", .{});
    try io.stdout.print("                         Accepts units: B, K, KB, M, MB, G, GB (e.g., 500MB).\n", .{});
    try io.stdout.print("  --persist-size <size>  Max capacity for Persistent Memory (default: 1GB).\n", .{});

    try io.stdout.print("\n", .{});
    _ = try io.stdout.flush();
}

pub fn helpRun(io: anytype) !void {
    const orange = "\x1b[38;5;208m";
    const bold = "\x1b[1m";
    const reset = "\x1b[0m";

    try io.stdout.print("{s}Usage:{s} flint {s}run{s} <file.fl> [script args...]\n\n", .{ bold, reset, orange, reset });
    try io.stdout.print("Compiles and executes the script in memory (JIT-like execution).\n", .{});
    try io.stdout.print("Arguments provided after the file name are passed directly to the script via `os.args()`.\n\n", .{});

    try io.stdout.print("{s}Example:{s}\n", .{ bold, reset });
    try io.stdout.print("  flint run script.fl --port 8080 --dev\n", .{});

    try io.stdout.print("\n", .{});
    _ = try io.stdout.flush();
}
