const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;
const AstNode = @import("../parser/ast.zig").AstNode;

pub const FlintType = enum {
    t_int,
    t_string,
    t_bool,
    t_val,
    t_arr,
    t_void,
    t_any,
    t_error,
    t_unknown,
};

pub const Symbol = struct {
    name: []const u8,
    type: FlintType,
    is_const: bool,
    line: u32,
    column: u32,
    node: ?*AstNode = null,
    struct_name: ?[]const u8 = null,
    builtin_signature: ?[]const FlintType = null,
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.StringHashMap(Symbol),
    enclosing: ?*SymbolTable,

    pub fn init(allocator: std.mem.Allocator, enclosing: ?*SymbolTable) SymbolTable {
        return .{
            .allocator = allocator,
            .symbols = std.StringHashMap(Symbol).init(allocator),
            .enclosing = enclosing,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit();
    }

    pub fn define(self: *SymbolTable, name: []const u8, sym_type: FlintType, is_const: bool, line: u32, col: u32, decl_node: ?*AstNode, builtin_signature: ?[]const FlintType) bool {
        if (self.symbols.contains(name)) {
            return false;
        }

        self.symbols.put(name, Symbol{
            .name = name,
            .type = sym_type,
            .is_const = is_const,
            .line = line,
            .column = col,
            .node = decl_node,
            .struct_name = null,
            .builtin_signature = builtin_signature,
        }) catch unreachable;

        return true;
    }

    pub fn lookup(self: *SymbolTable, name: []const u8) ?Symbol {
        if (self.symbols.get(name)) |symbol| {
            return symbol;
        }

        if (self.enclosing) |parent| {
            return parent.lookup(name);
        }

        return null;
    }
};
