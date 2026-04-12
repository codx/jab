const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const indent_mod = @import("../indent.zig");
const ts = @import("../treesitter.zig");
const RuleId = diagnostic.RuleId;
const Diagnostic = diagnostic.Diagnostic;
const DiagnosticList = diagnostic.DiagnosticList;
const SkipSet = diagnostic.SkipSet;
const FixResult = diagnostic.FixResult;

pub fn fix(
    allocator: std.mem.Allocator,
    source: []const u8,
    _: []const u8,
    skip: SkipSet,
    dry_run: bool,
) FixResult {
    var diags: DiagnosticList = .{};

    const parser = ts.Parser.init() orelse return noChange(source, &diags);
    defer parser.deinit();
    _ = parser.setLanguage(ts.languages.bash());

    const tree = parser.parse(source) orelse return noChange(source, &diags);
    defer ts.freeTree(tree);

    var replacements: std.ArrayList(Replacement) = .empty;

    var cursor = ts.cursorNew(ts.rootNode(tree));
    defer ts.cursorDelete(&cursor);

    visitNodes(&cursor, source, skip, allocator, &diags, &replacements);

    if (dry_run or replacements.items.len == 0) {
        return .{
            .output = source,
            .diagnostics = diags.slice(),
            .changed = false,
        };
    }

    const output = applyReplacements(allocator, source, replacements.items) orelse source;
    return .{
        .output = output,
        .diagnostics = diags.slice(),
        .changed = !std.mem.eql(u8, output, source),
    };
}

const Replacement = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

fn visitNodes(
    cursor: *ts.TreeCursor,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    var reached_root = false;
    while (!reached_root) {
        const node = ts.cursorNode(cursor);
        checkNode(node, source, skip, allocator, diags, replacements);

        if (ts.cursorGotoFirstChild(cursor)) continue;
        if (ts.cursorGotoNextSibling(cursor)) continue;

        var retracting = true;
        while (retracting) {
            if (!ts.cursorGotoParent(cursor)) {
                retracting = false;
                reached_root = true;
            } else {
                if (ts.cursorGotoNextSibling(cursor)) {
                    retracting = false;
                }
            }
        }
    }
}

fn checkNode(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    const node_type = ts.nodeType(node);

    if (std.mem.eql(u8, node_type, "simple_expansion") or
        std.mem.eql(u8, node_type, "expansion"))
    {
        checkUnquotedExpansion(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "command_substitution")) {
        checkUnquotedCommandSub(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "command_substitution")) {
        checkBacktickSyntax(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "command")) {
        checkCdWithoutErrorHandling(node, source, skip, allocator, diags, replacements);
    }
}

fn checkUnquotedExpansion(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    const parent = ts.nodeParent(node);
    if (ts.nodeIsNull(parent)) return;
    const parent_type = ts.nodeType(parent);

    if (std.mem.eql(u8, parent_type, "string")) return;
    if (std.mem.eql(u8, parent_type, "variable_assignment")) return;
    if (std.mem.eql(u8, parent_type, "binary_expression")) {
        if (isInsideTestCommand(parent, source)) return;
    }
    if (isInsideArithmetic(node)) return;
    if (std.mem.eql(u8, parent_type, "array")) return;
    if (std.mem.eql(u8, parent_type, "case_item")) return;
    if (isInsideHeredoc(node)) return;

    const text = ts.nodeText(node, source);
    if (text.len == 0) return;

    if (std.mem.eql(u8, text, "$@") or std.mem.eql(u8, text, "${@}")) {
        if (skip.shouldSkip(.bash_unquoted_at)) return;
        const point = ts.nodeStartPoint(node);
        diags.add(allocator, .{
            .rule = .bash_unquoted_at,
            .line = point.row + 1,
            .col = point.column + 1,
            .message = "Unquoted $@",
            .span_len = @intCast(text.len),
            .suggestion = "Use \"$@\"",
        }) catch {};
        const start = ts.nodeStartByte(node);
        const end = ts.nodeEndByte(node);
        const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{text}) catch return;
        replacements.append(allocator, .{ .start = start, .end = end, .text = quoted }) catch {};
        return;
    }

    if (skip.shouldSkip(.bash_unquoted_var)) return;
    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_unquoted_var,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Unquoted variable expansion",
        .span_len = @intCast(text.len),
        .suggestion = "Quote with double quotes",
    }) catch {};

    const start = ts.nodeStartByte(node);
    const end = ts.nodeEndByte(node);
    const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{text}) catch return;
    replacements.append(allocator, .{ .start = start, .end = end, .text = quoted }) catch {};
}

fn checkUnquotedCommandSub(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_unquoted_cmd_sub)) return;

    const parent = ts.nodeParent(node);
    if (ts.nodeIsNull(parent)) return;
    const parent_type = ts.nodeType(parent);
    if (std.mem.eql(u8, parent_type, "string")) return;
    if (std.mem.eql(u8, parent_type, "variable_assignment")) return;
    if (isInsideArithmetic(node)) return;
    if (isInsideHeredoc(node)) return;

    const text = ts.nodeText(node, source);
    if (text.len == 0) return;
    if (text[0] == '`') return;

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_unquoted_cmd_sub,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Unquoted command substitution",
        .span_len = @intCast(text.len),
        .suggestion = "Quote with double quotes",
    }) catch {};

    const start = ts.nodeStartByte(node);
    const end = ts.nodeEndByte(node);
    const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{text}) catch return;
    replacements.append(allocator, .{ .start = start, .end = end, .text = quoted }) catch {};
}

fn checkBacktickSyntax(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_backtick)) return;

    const text = ts.nodeText(node, source);
    if (text.len == 0 or text[0] != '`') return;

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_backtick,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Legacy backtick syntax",
        .span_len = @intCast(text.len),
        .suggestion = "Use $(...) instead",
    }) catch {};

    if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
        const inner = text[1 .. text.len - 1];
        const replacement = std.fmt.allocPrint(allocator, "$({s})", .{inner}) catch return;
        const start = ts.nodeStartByte(node);
        const end = ts.nodeEndByte(node);
        replacements.append(allocator, .{ .start = start, .end = end, .text = replacement }) catch {};
    }
}

fn checkCdWithoutErrorHandling(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    _: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_cd_no_check)) return;

    const child_count = ts.nodeChildCount(node);
    if (child_count == 0) return;

    const first_child = ts.nodeChild(node, 0);
    const cmd_name = ts.nodeText(first_child, source);
    if (!std.mem.eql(u8, cmd_name, "cd")) return;

    const parent = ts.nodeParent(node);
    if (!ts.nodeIsNull(parent)) {
        const parent_type = ts.nodeType(parent);
        if (std.mem.eql(u8, parent_type, "list")) {
            const pcount = ts.nodeChildCount(parent);
            var ci: u32 = 0;
            while (ci < pcount) : (ci += 1) {
                const sibling = ts.nodeChild(parent, ci);
                const stype = ts.nodeType(sibling);
                if (std.mem.eql(u8, stype, "||") or std.mem.eql(u8, stype, "&&")) return;
            }
        }
        if (std.mem.eql(u8, parent_type, "if_statement") or
            std.mem.eql(u8, parent_type, "subshell"))
        {
            return;
        }
    }

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_cd_no_check,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "cd without error handling",
        .span_len = @intCast(ts.nodeEndByte(node) - ts.nodeStartByte(node)),
        .suggestion = "Add || exit 1",
    }) catch {};
}

fn isInsideTestCommand(node: ts.Node, source: []const u8) bool {
    var current = node;
    while (!ts.nodeIsNull(current)) {
        const ntype = ts.nodeType(current);
        if (std.mem.eql(u8, ntype, "test_command")) return true;
        if (std.mem.eql(u8, ntype, "command")) {
            const child_count = ts.nodeChildCount(current);
            if (child_count > 0) {
                const first = ts.nodeChild(current, 0);
                const text = ts.nodeText(first, source);
                if (std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "test")) return true;
            }
        }
        current = ts.nodeParent(current);
    }
    return false;
}

fn isInsideArithmetic(node: ts.Node) bool {
    var current = node;
    while (!ts.nodeIsNull(current)) {
        const ntype = ts.nodeType(current);
        if (std.mem.eql(u8, ntype, "arithmetic_expansion")) return true;
        current = ts.nodeParent(current);
    }
    return false;
}

fn isInsideHeredoc(node: ts.Node) bool {
    var current = node;
    while (!ts.nodeIsNull(current)) {
        const ntype = ts.nodeType(current);
        if (std.mem.eql(u8, ntype, "heredoc_body")) return true;
        if (std.mem.eql(u8, ntype, "heredoc_redirect")) return true;
        current = ts.nodeParent(current);
    }
    return false;
}

fn applyReplacements(allocator: std.mem.Allocator, source: []const u8, replacements: []const Replacement) ?[]const u8 {
    var sorted: std.ArrayList(Replacement) = .empty;
    sorted.appendSlice(allocator, replacements) catch return null;
    std.mem.sortUnstable(Replacement, sorted.items, {}, struct {
        fn lessThan(_: void, a: Replacement, b: Replacement) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var result: std.ArrayList(u8) = .empty;
    var pos: u32 = 0;
    for (sorted.items) |r| {
        if (r.start < pos) continue;
        result.appendSlice(allocator, source[pos..r.start]) catch return null;
        result.appendSlice(allocator, r.text) catch return null;
        pos = r.end;
    }
    result.appendSlice(allocator, source[pos..]) catch return null;
    return result.items;
}

fn noChange(source: []const u8, diags: *DiagnosticList) FixResult {
    return .{
        .output = source,
        .diagnostics = diags.slice(),
        .changed = false,
    };
}

test "JB1003 backtick detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nfoo=`echo hello`\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_backtick) found = true;
    }
    try std.testing.expect(found);
}

test "JB1004 cd without error handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\ncd /tmp\necho done\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_cd_no_check) found = true;
    }
    try std.testing.expect(found);
}

test "JB1004 cd with || exit is clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\ncd /tmp || exit 1\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_cd_no_check) found = true;
    }
    try std.testing.expect(!found);
}

test "clean bash no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\necho \"hello\"\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
