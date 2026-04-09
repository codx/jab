const std = @import("std");

const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

pub const Language = *const c.TSLanguage;
pub const Tree = *c.TSTree;
pub const Node = c.TSNode;
pub const TreeCursor = c.TSTreeCursor;

extern fn tree_sitter_bash() Language;
extern fn tree_sitter_python() Language;
extern fn tree_sitter_hcl() Language;

pub const languages = struct {
    pub const bash = tree_sitter_bash;
    pub const python = tree_sitter_python;
    pub const hcl = tree_sitter_hcl;
};

pub const Parser = struct {
    ptr: *c.TSParser,

    pub fn init() ?Parser {
        const p = c.ts_parser_new() orelse return null;
        return .{ .ptr = p };
    }

    pub fn deinit(self: Parser) void {
        c.ts_parser_delete(self.ptr);
    }

    pub fn setLanguage(self: Parser, lang: Language) bool {
        return c.ts_parser_set_language(self.ptr, lang);
    }

    pub fn parse(self: Parser, source: []const u8) ?Tree {
        return c.ts_parser_parse_string(self.ptr, null, source.ptr, @intCast(source.len));
    }
};

pub fn rootNode(tree: Tree) Node {
    return c.ts_tree_root_node(tree);
}

pub fn freeTree(tree: Tree) void {
    c.ts_tree_delete(tree);
}

pub fn nodeType(node: Node) []const u8 {
    const t = c.ts_node_type(node);
    return std.mem.span(t);
}

pub fn nodeChildCount(node: Node) u32 {
    return c.ts_node_child_count(node);
}

pub fn nodeNamedChildCount(node: Node) u32 {
    return c.ts_node_named_child_count(node);
}

pub fn nodeChild(node: Node, index: u32) Node {
    return c.ts_node_child(node, index);
}

pub fn nodeNamedChild(node: Node, index: u32) Node {
    return c.ts_node_named_child(node, index);
}

pub fn nodeParent(node: Node) Node {
    return c.ts_node_parent(node);
}

pub fn nodeStartByte(node: Node) u32 {
    return c.ts_node_start_byte(node);
}

pub fn nodeEndByte(node: Node) u32 {
    return c.ts_node_end_byte(node);
}

pub fn nodeStartPoint(node: Node) c.TSPoint {
    return c.ts_node_start_point(node);
}

pub fn nodeEndPoint(node: Node) c.TSPoint {
    return c.ts_node_end_point(node);
}

pub fn nodeIsNull(node: Node) bool {
    return c.ts_node_is_null(node);
}

pub fn nodeIsNamed(node: Node) bool {
    return c.ts_node_is_named(node);
}

pub fn nodeText(node: Node, source: []const u8) []const u8 {
    const start = nodeStartByte(node);
    const end = nodeEndByte(node);
    if (start >= source.len or end > source.len) return "";
    return source[start..end];
}

pub fn nodeFieldNameForChild(node: Node, index: u32) ?[]const u8 {
    const name = c.ts_node_field_name_for_child(node, index);
    if (name == null) return null;
    return std.mem.span(name);
}

pub fn cursorNew(node: Node) TreeCursor {
    return c.ts_tree_cursor_new(node);
}

pub fn cursorDelete(cursor: *TreeCursor) void {
    c.ts_tree_cursor_delete(cursor);
}

pub fn cursorNode(cursor: *const TreeCursor) Node {
    return c.ts_tree_cursor_current_node(cursor);
}

pub fn cursorGotoFirstChild(cursor: *TreeCursor) bool {
    return c.ts_tree_cursor_goto_first_child(cursor);
}

pub fn cursorGotoNextSibling(cursor: *TreeCursor) bool {
    return c.ts_tree_cursor_goto_next_sibling(cursor);
}

pub fn cursorGotoParent(cursor: *TreeCursor) bool {
    return c.ts_tree_cursor_goto_parent(cursor);
}

pub fn cursorCurrentFieldName(cursor: *const TreeCursor) ?[]const u8 {
    const name = c.ts_tree_cursor_current_field_name(cursor);
    if (name == null) return null;
    return std.mem.span(name);
}

pub fn walkTree(tree: Tree, source: []const u8, callback: *const fn (Node, []const u8, u32) void) void {
    var cursor = cursorNew(rootNode(tree));
    defer cursorDelete(&cursor);
    var depth: u32 = 0;

    var reached_root = false;
    while (!reached_root) {
        callback(cursorNode(&cursor), source, depth);

        if (cursorGotoFirstChild(&cursor)) {
            depth += 1;
            continue;
        }

        if (cursorGotoNextSibling(&cursor)) {
            continue;
        }

        var retracting = true;
        while (retracting) {
            if (!cursorGotoParent(&cursor)) {
                retracting = false;
                reached_root = true;
            } else {
                depth -= 1;
                if (cursorGotoNextSibling(&cursor)) {
                    retracting = false;
                }
            }
        }
    }
}

test "parser init" {
    const parser = Parser.init() orelse {
        return error.ParserInitFailed;
    };
    defer parser.deinit();
    _ = parser.setLanguage(languages.bash());
}

test "parse bash" {
    const parser = Parser.init() orelse return error.ParserInitFailed;
    defer parser.deinit();
    _ = parser.setLanguage(languages.bash());

    const source = "#!/bin/bash\necho hello\n";
    const tree = parser.parse(source) orelse return error.ParseFailed;
    defer freeTree(tree);

    const root = rootNode(tree);
    try std.testing.expectEqualStrings("program", nodeType(root));
}
