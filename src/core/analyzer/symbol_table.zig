const std = @import("std");
const Token = @import("../lexer/structs/token.zig").Token;
const ast = @import("../parser/ast.zig");
const StringId = ast.StringId;

pub const FlintType = enum {
    t_int,
    t_string,
    t_bool,
    t_val,
    t_int_arr,
    t_str_arr,
    t_bool_arr,
    t_void,
    t_any,
    t_error,
    t_unknown,
};

pub const Symbol = struct {
    name_id: StringId,
    type: FlintType,
    is_const: bool,
    line: u32,
    column: u32,
    node: ?u32,
    struct_name_id: ?StringId = null,
    builtin_signature: ?[]const FlintType = null,
};

pub const SymbolTable = struct {
    allocator: std.mem.Allocator,
    symbols: std.AutoHashMap(StringId, Symbol),
    enclosing: ?*SymbolTable,

    pub fn init(allocator: std.mem.Allocator, enclosing: ?*SymbolTable) SymbolTable {
        return .{
            .allocator = allocator,
            .symbols = std.AutoHashMap(StringId, Symbol).init(allocator),
            .enclosing = enclosing,
        };
    }

    pub fn deinit(self: *SymbolTable) void {
        self.symbols.deinit();
    }

    pub fn define(self: *SymbolTable, name_id: StringId, sym_type: FlintType, is_const: bool, line: u32, col: u32, decl_node: ?u32, builtin_signature: ?[]const FlintType) bool {
        if (self.symbols.contains(name_id)) {
            return false;
        }

        self.symbols.put(name_id, Symbol{
            .name_id = name_id,
            .type = sym_type,
            .is_const = is_const,
            .line = line,
            .column = col,
            .node = decl_node,
            .struct_name_id = null,
            .builtin_signature = builtin_signature,
        }) catch unreachable;

        return true;
    }

    pub fn lookup(self: *SymbolTable, name_id: StringId) ?Symbol {
        if (self.symbols.get(name_id)) |symbol| {
            return symbol;
        }

        if (self.enclosing) |parent| {
            return parent.lookup(name_id);
        }

        return null;
    }
};
