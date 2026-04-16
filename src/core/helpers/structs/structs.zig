const std = @import("std");

pub const IoHelpers = struct {
    sys: std.process.Init,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};
