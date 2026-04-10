const std = @import("std");

pub const SourceFile = struct {
    id: u32,
    path: []const u8,
    content: []const u8,
};

pub const SourceManager = struct {
    allocator: std.mem.Allocator,
    files: std.ArrayList(SourceFile),

    pub fn init(allocator: std.mem.Allocator) SourceManager {
        return .{
            .allocator = allocator,
            .files = std.ArrayList(SourceFile).empty,
        };
    }

    pub fn deinit(self: *SourceManager) void {
        self.files.deinit(self.allocator);
    }

    pub fn addFile(self: *SourceManager, path: []const u8, content: []const u8) !u32 {
        const id = @as(u32, @intCast(self.files.items.len));
        try self.files.append(self.allocator, .{
            .id = id,
            .path = path,
            .content = content,
        });
        return id;
    }

    pub fn getFile(self: *const SourceManager, id: u32) ?SourceFile {
        if (id >= self.files.items.len) return null;
        return self.files.items[id];
    }
};
