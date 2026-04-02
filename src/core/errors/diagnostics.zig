const std = @import("std");
const IoHelpers = @import("../helpers/structs/structs.zig").IoHelpers;

pub const DiagnosticLabel = struct {
    line: u32,
    col: u32,
    len: u32,
    text: []const u8,
    is_primary: bool,
};

pub const DiagnosticBuilder = struct {
    allocator: std.mem.Allocator,
    category: []const u8,
    code: []const u8,
    message: []const u8,

    source: []const u8,
    file_path: []const u8,

    labels: std.ArrayList(DiagnosticLabel),
    note_msg: ?[]const u8 = null,
    help_msg: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, category: []const u8, code: []const u8, message: []const u8, source: []const u8, file_path: []const u8) DiagnosticBuilder {
        return .{
            .allocator = allocator,
            .category = category,
            .code = code,
            .message = message,
            .source = source,
            .file_path = file_path,
            .labels = std.ArrayList(DiagnosticLabel).empty,
        };
    }

    pub fn deinit(self: *DiagnosticBuilder) void {
        self.labels.deinit(self.allocator);
    }

    pub fn addLabel(self: *DiagnosticBuilder, line: u32, end_col: u32, len: u32, text: []const u8, is_primary: bool) !void {
        const start_col = if (end_col >= len) end_col - len else 0;
        try self.labels.append(self.allocator, .{
            .line = line,
            .col = start_col,
            .len = len,
            .text = text,
            .is_primary = is_primary,
        });
    }

    pub fn note(self: *DiagnosticBuilder, msg: []const u8) void {
        self.note_msg = msg;
    }

    pub fn help(self: *DiagnosticBuilder, msg: []const u8) void {
        self.help_msg = msg;
    }

    pub fn emit(self: *DiagnosticBuilder, io: IoHelpers) !void {
        const red = "\x1b[1;31m";
        const cyan = "\x1b[1;36m";
        const blue = "\x1b[1;34m";
        const yellow = "\x1b[1;33m";
        const bold = "\x1b[1m";
        const reset = "\x1b[0m";

        try io.stderr.print("[{s}{s}{s}][{s}{s}{s}]: {s}{s}{s}\n\n", .{ red, self.category, reset, yellow, self.code, reset, bold, self.message, reset });

        if (self.labels.items.len == 0) return;
        const target_line = self.labels.items[0].line;

        var lines = std.mem.splitScalar(u8, self.source, '\n');
        var current_line: u32 = 0;
        var target_line_text: []const u8 = "";
        while (lines.next()) |l| : (current_line += 1) {
            if (current_line == target_line) {
                target_line_text = l;
                break;
            }
        }

        try io.stderr.print("{s}~~>{s} {s}:{d}\n", .{ cyan, reset, self.file_path, target_line + 1 });
        try io.stderr.print("   {s}|{s}\n", .{ cyan, reset });
        try io.stderr.print("{d:2} {s}|{s} {s}\n", .{ target_line + 1, cyan, reset, target_line_text });

        std.mem.sort(DiagnosticLabel, self.labels.items, {}, struct {
            fn lessThan(_: void, a: DiagnosticLabel, b: DiagnosticLabel) bool {
                return a.col > b.col;
            }
        }.lessThan);

        try io.stderr.print("   {s}|{s} ", .{ cyan, reset });
        var cursor: u32 = 0;

        var left_to_right = try self.labels.clone(self.allocator);
        defer left_to_right.deinit(self.allocator);
        std.mem.sort(DiagnosticLabel, left_to_right.items, {}, struct {
            fn lessThan(_: void, a: DiagnosticLabel, b: DiagnosticLabel) bool {
                return a.col < b.col;
            }
        }.lessThan);

        for (left_to_right.items) |lbl| {
            while (cursor < lbl.col) : (cursor += 1) {
                try io.stderr.print(" ", .{});
            }
            const color = if (lbl.is_primary) red else blue;
            try io.stderr.print("{s}^{s}", .{ color, reset });
            cursor += 1;
            var i: u32 = 1;
            while (i < lbl.len) : (i += 1) {
                try io.stderr.print("{s}~{s}", .{ color, reset });
                cursor += 1;
            }
        }
        try io.stderr.print("\n", .{});

        for (self.labels.items, 0..) |current_lbl, idx| {
            try io.stderr.print("   {s}|{s} ", .{ cyan, reset });
            cursor = 0;

            const labels_to_left = self.labels.items[idx + 1 ..];
            var j: usize = labels_to_left.len;
            while (j > 0) {
                j -= 1;
                const left_lbl = labels_to_left[j];
                while (cursor < left_lbl.col) : (cursor += 1) {
                    try io.stderr.print(" ", .{});
                }
                const color = if (left_lbl.is_primary) red else blue;
                try io.stderr.print("{s}|{s}", .{ color, reset });
                cursor += 1;
            }

            while (cursor < current_lbl.col) : (cursor += 1) {
                try io.stderr.print(" ", .{});
            }
            const cur_color = if (current_lbl.is_primary) red else blue;
            try io.stderr.print("{s}|{s}\n", .{ cur_color, reset });

            try io.stderr.print("   {s}|{s} ", .{ cyan, reset });
            cursor = 0;
            j = labels_to_left.len;
            while (j > 0) {
                j -= 1;
                const left_lbl = labels_to_left[j];
                while (cursor < left_lbl.col) : (cursor += 1) {
                    try io.stderr.print(" ", .{});
                }
                const color = if (left_lbl.is_primary) red else blue;
                try io.stderr.print("{s}|{s}", .{ color, reset });
                cursor += 1;
            }
            while (cursor < current_lbl.col) : (cursor += 1) {
                try io.stderr.print(" ", .{});
            }
            try io.stderr.print("{s}{s}{s}\n", .{ cur_color, current_lbl.text, reset });
        }

        try io.stderr.print("   {s}|{s}\n", .{ cyan, reset });

        if (self.note_msg) |n| {
            try io.stderr.print("\n{s}note{s}: {s}", .{ cyan, reset, n });

            if (self.help_msg) |_| {
                //
            } else {
                try io.stderr.print("\n", .{});
            }
        }

        if (self.help_msg) |h| {
            try io.stderr.print("\n{s}help{s}: {s}\n", .{ yellow, reset, h });
        }

        try io.stderr.print("\n", .{});
        _ = try io.stderr.flush();
    }
};
