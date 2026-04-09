const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
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
    _ = parser.setLanguage(ts.languages.python());

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

    if (std.mem.eql(u8, node_type, "except_clause")) {
        checkBareExcept(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "comparison_operator")) {
        checkComparisonWithNone(node, source, skip, allocator, diags, replacements);
        checkComparisonWithBool(node, source, skip, allocator, diags, replacements);
    }
}

fn checkBareExcept(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.JB2001)) return;

    const child_count = ts.nodeChildCount(node);
    var has_exception_type = false;
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const ctype = ts.nodeType(child);
        if (std.mem.eql(u8, ctype, "identifier") or
            std.mem.eql(u8, ctype, "dotted_name") or
            std.mem.eql(u8, ctype, "as_pattern") or
            std.mem.eql(u8, ctype, "tuple"))
        {
            has_exception_type = true;
            break;
        }
    }

    if (!has_exception_type) {
        const text = ts.nodeText(node, source);
        const except_end = std.mem.indexOf(u8, text, ":") orelse return;
        const except_text = std.mem.trim(u8, text[0..except_end], " \t");
        if (!std.mem.eql(u8, except_text, "except")) return;

        const point = ts.nodeStartPoint(node);
        diags.add(allocator, .{
            .rule = .JB2001,
            .line = point.row + 1,
            .col = point.column + 1,
            .message = "Bare except clause",
            .span_len = 6,
            .suggestion = "Use except Exception:",
        }) catch {};

        const start = ts.nodeStartByte(node);
        const colon_offset = @as(u32, @intCast(except_end));
        replacements.append(allocator, .{
            .start = start,
            .end = start + colon_offset,
            .text = "except Exception",
        }) catch {};
    }
}

fn checkComparisonWithNone(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.JB2002)) return;

    const child_count = ts.nodeChildCount(node);
    if (child_count < 3) return;

    var i: u32 = 0;
    while (i + 2 < child_count) : (i += 1) {
        const left = ts.nodeChild(node, i);
        const op = ts.nodeChild(node, i + 1);
        const right = ts.nodeChild(node, i + 2);

        const op_text = ts.nodeText(op, source);
        const is_eq = std.mem.eql(u8, op_text, "==");
        const is_neq = std.mem.eql(u8, op_text, "!=");
        if (!is_eq and !is_neq) continue;

        const left_text = ts.nodeText(left, source);
        const right_text = ts.nodeText(right, source);

        const none_on_right = std.mem.eql(u8, right_text, "None");
        const none_on_left = std.mem.eql(u8, left_text, "None");

        if (!none_on_right and !none_on_left) continue;

        const point = ts.nodeStartPoint(op);
        const replacement_op: []const u8 = if (is_eq) "is" else "is not";
        diags.add(allocator, .{
            .rule = .JB2002,
            .line = point.row + 1,
            .col = point.column + 1,
            .message = if (is_eq) "Use 'is None' instead of '== None'" else "Use 'is not None' instead of '!= None'",
            .span_len = @intCast(op_text.len),
            .suggestion = replacement_op,
        }) catch {};

        const op_start = ts.nodeStartByte(op);
        const op_end = ts.nodeEndByte(op);
        replacements.append(allocator, .{
            .start = op_start,
            .end = op_end,
            .text = replacement_op,
        }) catch {};
    }
}

fn checkComparisonWithBool(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    _: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.JB2003)) return;

    const child_count = ts.nodeChildCount(node);
    if (child_count < 3) return;

    var i: u32 = 0;
    while (i + 2 < child_count) : (i += 1) {
        const left = ts.nodeChild(node, i);
        const op = ts.nodeChild(node, i + 1);
        const right = ts.nodeChild(node, i + 2);

        const op_text = ts.nodeText(op, source);
        if (!std.mem.eql(u8, op_text, "==") and !std.mem.eql(u8, op_text, "!=")) continue;

        const left_text = ts.nodeText(left, source);
        const right_text = ts.nodeText(right, source);

        const bool_on_right = std.mem.eql(u8, right_text, "True") or std.mem.eql(u8, right_text, "False");
        const bool_on_left = std.mem.eql(u8, left_text, "True") or std.mem.eql(u8, left_text, "False");

        if (!bool_on_right and !bool_on_left) continue;

        const point = ts.nodeStartPoint(op);
        diags.add(allocator, .{
            .rule = .JB2003,
            .line = point.row + 1,
            .col = point.column + 1,
            .message = "Comparison with True/False",
            .span_len = @intCast(ts.nodeEndByte(node) - ts.nodeStartByte(node)),
            .suggestion = "Use truthiness test instead",
        }) catch {};
    }
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

test "JB2001 bare except" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "try:\n    pass\nexcept:\n    pass\n";
    const result = fix(alloc, source, "test.py", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB2001) found = true;
    }
    try std.testing.expect(found);
}

test "JB2001 fix bare except" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "try:\n    pass\nexcept:\n    pass\n";
    const result = fix(alloc, source, "test.py", SkipSet{}, false);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "except Exception:") != null);
}

test "JB2002 equality with None" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "if x == None:\n    pass\n";
    const result = fix(alloc, source, "test.py", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB2002) found = true;
    }
    try std.testing.expect(found);
}

test "JB2002 fix replaces == with is" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "if x == None:\n    pass\n";
    const result = fix(alloc, source, "test.py", SkipSet{}, false);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "x is None") != null);
}

test "JB2003 comparison with True" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "if x == True:\n    pass\n";
    const result = fix(alloc, source, "test.py", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB2003) found = true;
    }
    try std.testing.expect(found);
}

test "clean Python no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "if x is None:\n    pass\n";
    const result = fix(alloc, source, "test.py", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
