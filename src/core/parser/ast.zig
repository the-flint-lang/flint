const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;

pub const NodeIndex = u32;

pub const StringId = u32;

pub const StringPool = struct {
    map: std.StringHashMap(StringId),
    list: std.ArrayList([]const u8),

    pub fn init(allocator: std.mem.Allocator) StringPool {
        return .{
            .map = std.StringHashMap(StringId).init(allocator),
            .list = std.ArrayList([]const u8).empty,
        };
    }

    pub fn deinit(self: *StringPool, alloc: std.mem.Allocator) void {
        self.map.deinit();
        self.list.deinit(alloc);
    }

    pub fn intern(self: *StringPool, alloc: std.mem.Allocator, str: []const u8) !StringId {
        if (self.map.get(str)) |id| {
            return id;
        }

        const id = @as(StringId, @intCast(self.list.items.len));
        try self.list.append(alloc, str);
        try self.map.put(str, id);
        return id;
    }

    pub fn get(self: *const StringPool, id: StringId) []const u8 {
        return self.list.items[id];
    }
};

pub const AstNode = union(enum) {
    program: struct {
        statements: []const NodeIndex,
    },

    function_decl: struct {
        is_extern: bool,
        name_id: StringId,
        return_type: Token,
        arguments: []const NodeIndex,
        body: []const NodeIndex,
    },

    var_decl: struct {
        line: u32,
        _type: ?Token,
        is_const: bool,
        name_id: StringId,
        value: NodeIndex,
    },

    struct_decl: struct {
        name_id: StringId,
        fields: []const StructField,
    },

    import_stmt: struct {
        path: []const u8,
        alias_id: ?StringId,
    },

    return_stmt: struct {
        value: ?NodeIndex,
    },

    if_stmt: struct {
        condition: NodeIndex,
        then_branch: []const NodeIndex,
        else_branch: ?[]const NodeIndex,
    },

    call_expr: struct {
        line: u32,
        callee: NodeIndex,
        arguments: []const NodeIndex,
    },

    binary_expr: struct {
        left: NodeIndex,
        operator: Token,
        right: NodeIndex,
    },

    logical_and: LogicalExpr,
    logical_or: LogicalExpr,

    slice_expr: struct {
        left: NodeIndex,
        start: ?NodeIndex,
        end: ?NodeIndex,
    },

    unary_expr: struct {
        operator: Token,
        right: NodeIndex,
    },

    index_expr: struct {
        left: NodeIndex,
        index: NodeIndex,
    },

    property_access_expr: struct {
        line: u32,
        object: NodeIndex,
        property_name_id: StringId,
    },

    array_expr: struct {
        elements: []const NodeIndex,
    },

    dict_expr: struct {
        entries: []const DictEntry,
    },

    pipeline_expr: struct {
        left: NodeIndex,
        right_call: NodeIndex,
    },

    for_stmt: struct {
        iterator_name_id: StringId,
        iterable: NodeIndex,
        body: []const NodeIndex,
        is_stream: bool,
    },

    catch_expr: CatchExpr,

    identifier: struct {
        _type: Token,
        name_id: StringId,
    },

    literal: struct {
        token: Token,
    },
};

pub const LogicalExpr = struct {
    left: NodeIndex,
    operator: Token,
    right: NodeIndex,
};

pub const DictEntry = struct {
    key: NodeIndex,
    value: NodeIndex,
};

pub const CatchExpr = struct {
    expression: NodeIndex,
    error_identifier_id: StringId,
    body: []const NodeIndex,
};

pub const StructField = struct {
    name_id: StringId,
    _type: Token,
};

pub const AstTree = struct {
    nodes: std.ArrayList(AstNode),

    pub fn init() AstTree {
        return .{
            .nodes = std.ArrayList(AstNode).empty,
        };
    }

    pub fn deinit(self: *AstTree, allocator: std.mem.Allocator) void {
        self.nodes.deinit(allocator);
    }

    pub fn addNode(self: *AstTree, allocator: std.mem.Allocator, node: AstNode) !NodeIndex {
        const index = @as(NodeIndex, @intCast(self.nodes.items.len));
        try self.nodes.append(allocator, node);
        return index;
    }

    pub fn getNode(self: AstTree, index: NodeIndex) AstNode {
        return self.nodes.items[index];
    }
};
