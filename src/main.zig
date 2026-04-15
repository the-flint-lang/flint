const std = @import("std");

const flint = @import("flint");
const IoHelper = flint.IoHelper;

pub fn main() !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    var stderr_writer = std.fs.File.stderr().writer(&stderr_buffer);

    defer {
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
    }

    const io = IoHelper{
        .stdout = &stdout_writer,
        .stderr = &stderr_writer,
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
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
        std.process.exit(1);
    };
}
