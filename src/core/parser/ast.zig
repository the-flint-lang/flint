const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;

pub const NodeIndex = u32;

pub const AstNode = union(enum) {
    program: struct {
        statements: []const NodeIndex,
    },

    function_decl: struct {
        is_extern: bool,
        name: []const u8,
        return_type: Token,
        arguments: []const NodeIndex,
        body: []const NodeIndex,
    },

    var_decl: struct {
        line: u32,
        _type: ?Token,
        is_const: bool,
        name: []const u8,
        value: NodeIndex,
    },

    struct_decl: struct {
        name: []const u8,
        fields: []const StructField,
    },

    import_stmt: struct {
        path: []const u8,
        alias: ?[]const u8,
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
        property_name: []const u8,
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
        iterator_name: []const u8,
        iterable: NodeIndex,
        body: []const NodeIndex,
    },

    catch_expr: CatchExpr,

    identifier: struct {
        _type: Token,
        name: []const u8,
    },

    literal: struct {
        token: Token,
    },
};

pub const DictEntry = struct {
    key: NodeIndex,
    value: NodeIndex,
};

pub const CatchExpr = struct {
    expression: NodeIndex,
    error_identifier: []const u8,
    body: []const NodeIndex,
};

pub const StructField = struct {
    name: []const u8,
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
