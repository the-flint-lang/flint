const std = @import("std");

const flint = @import("flint");
const IoHelper = flint.IoHelper;

pub fn main(init: std.process.Init) !void {
    var stdout_buffer: [4096]u8 = undefined;
    var stderr_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    var stderr_writer = std.Io.File.stderr().writer(init.io, &stderr_buffer);

    defer {
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
    }

    const io = IoHelper{
        .sys = init,
        .stdout = &stdout_writer.interface,
        .stderr = &stderr_writer.interface,
    };

    const gpa = init.gpa;

    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();

    const alloc = arena.allocator();

    const args = try init.minimal.args.toSlice(alloc);

    flint.runCli(alloc, io, args) catch {
        stdout_writer.flush() catch {};
        stderr_writer.flush() catch {};
        std.process.exit(1);
    };
}
