const std = @import("std");
const flint = @import("flint");
const IoHelper = flint.IoHelper;

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    defer {
        _ = stdout_writer.interface.flush() catch {};
        _ = stderr_writer.interface.flush() catch {};
    }

    const io = IoHelper{
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    };

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            io.stderr.print("\n\x1b[1;31m[CRITICAL ALERT]\x1b[0m Memory Leak Detected in the Compiler!\n", .{}) catch {};
        }
    }

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    const alloc = arena.allocator();

    flint.runCli(alloc, io) catch {
        _ = stdout_writer.interface.flush() catch {};
        _ = stderr_writer.interface.flush() catch {};
        std.process.exit(1);
    };
}
