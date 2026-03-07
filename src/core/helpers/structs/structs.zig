const std = @import("std");

pub const IoHelpers = struct {
    stdout: *std.io.Writer,
    stderr: *std.io.Writer,
};
