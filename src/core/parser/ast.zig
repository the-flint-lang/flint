const std = @import("std");

const Token = @import("../lexer/structs/token.zig").Token;

pub const NodeType = enum {
    program,

    function_decl,
    var_decl,
    struct_decl,
    import_stmt,
    return_stmt,
    if_stmt,

    call_expr,
    binary_expr,
    unary_expr,

    index_expr,
    property_access_expr,
    array_expr,
    dict_expr,

    pipeline_expr,
    for_stmt,
    catch_expr,

    identifier,
    literal,
};

pub const AstNode = union(NodeType) {
    program: struct {
        statements: []const *AstNode,
    },

    function_decl: struct {
        name: []const u8,
        return_type: Token,
        arguments: []const *AstNode,
        body: []const *AstNode,
    },

    var_decl: struct {
        line: u32,
        _type: ?Token,
        is_const: bool,
        name: []const u8,
        value: *AstNode,
    },

    struct_decl: struct {
        name: []const u8,
        fields: []const *StructField,
    },

    import_stmt: struct {
        path: []const u8,
        alias: ?[]const u8,
    },

    return_stmt: struct {
        value: ?*AstNode,
    },

    if_stmt: struct {
        condition: *AstNode,
        then_branch: []const *AstNode,
        else_branch: ?[]const *AstNode,
    },

    call_expr: struct {
        line: u32,
        callee: *AstNode,
        arguments: []const *AstNode,
    },

    binary_expr: struct {
        left: *AstNode,
        operator: Token,
        right: *AstNode,
    },

    unary_expr: struct {
        operator: Token,
        right: *AstNode,
    },

    index_expr: struct {
        left: *AstNode,
        index: *AstNode,
    },

    property_access_expr: struct {
        line: u32,
        object: *AstNode,
        property_name: []const u8,
    },

    array_expr: struct {
        elements: []const *AstNode,
    },

    dict_expr: struct {
        entries: []const *DictEntry,
    },

    pipeline_expr: struct {
        left: *AstNode,
        right_call: *AstNode,
    },

    for_stmt: struct {
        iterator_name: []const u8,
        iterable: *AstNode,
        body: []const *AstNode,
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
    key: *AstNode,
    value: *AstNode,
};

pub const CatchExpr = struct {
    expression: *AstNode,
    error_identifier: []const u8,
    body: []*AstNode,
};

pub const StructField = struct {
    name: []const u8,
    _type: Token,
};
