const std = @import("std");
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;

pub fn debugError(io: IoHelpers, comptime msg: []const u8, args: anytype) !void {
    try io.stdout.print(msg, args);

    try io.stdout.flush();
}
