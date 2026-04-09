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
    _ = parser.setLanguage(ts.languages.hcl());

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

    if (std.mem.eql(u8, node_type, "quoted_template")) {
        checkInterpolationOnly(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "body") or std.mem.eql(u8, node_type, "config_file")) {
        checkDuplicateBlockLabels(node, source, skip, allocator, diags);
    }
}

fn checkInterpolationOnly(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.JB3001)) return;

    const child_count = ts.nodeChildCount(node);
    if (child_count != 3) return;

    const first = ts.nodeChild(node, 0);
    const middle = ts.nodeChild(node, 1);
    const last = ts.nodeChild(node, 2);

    if (!std.mem.eql(u8, ts.nodeType(first), "quoted_template_start")) return;
    if (!std.mem.eql(u8, ts.nodeType(middle), "template_interpolation")) return;
    if (!std.mem.eql(u8, ts.nodeType(last), "quoted_template_end")) return;

    const interp_child_count = ts.nodeChildCount(middle);
    var expr_node: ?ts.Node = null;
    var ci: u32 = 0;
    while (ci < interp_child_count) : (ci += 1) {
        const ch = ts.nodeChild(middle, ci);
        const chtype = ts.nodeType(ch);
        if (std.mem.eql(u8, chtype, "expression")) {
            expr_node = ch;
            break;
        }
    }
    const expr = expr_node orelse return;
    const expr_text = ts.nodeText(expr, source);

    const qt_text = ts.nodeText(node, source);
    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .JB3001,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Deprecated interpolation-only expression",
        .span_len = @intCast(qt_text.len),
        .suggestion = expr_text,
    }) catch {};

    const start = ts.nodeStartByte(node);
    const end = ts.nodeEndByte(node);
    replacements.append(allocator, .{
        .start = start,
        .end = end,
        .text = allocator.dupe(u8, expr_text) catch return,
    }) catch {};
}

fn checkDuplicateBlockLabels(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
) void {
    if (skip.shouldSkip(.JB3002)) return;

    const child_count = ts.nodeChildCount(node);
    var seen: [128]BlockId = undefined;
    var seen_count: usize = 0;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const ctype = ts.nodeType(child);
        if (!std.mem.eql(u8, ctype, "block")) continue;

        const block_id = extractBlockId(child, source) orelse continue;

        for (seen[0..seen_count]) |s| {
            if (std.mem.eql(u8, s.block_type, block_id.block_type) and
                std.mem.eql(u8, s.label, block_id.label))
            {
                const point = ts.nodeStartPoint(child);
                diags.add(allocator, .{
                    .rule = .JB3002,
                    .line = point.row + 1,
                    .col = point.column + 1,
                    .message = "Duplicate block labels",
                    .span_len = @intCast(block_id.block_type.len + 1 + block_id.label.len),
                }) catch {};
                break;
            }
        }

        if (seen_count < 128) {
            seen[seen_count] = block_id;
            seen_count += 1;
        }
    }
}

const BlockId = struct {
    block_type: []const u8,
    label: []const u8,
};

fn extractBlockId(block_node: ts.Node, source: []const u8) ?BlockId {
    const child_count = ts.nodeChildCount(block_node);
    if (child_count < 2) return null;

    var block_type: ?[]const u8 = null;
    var label: ?[]const u8 = null;

    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(block_node, i);
        const ctype = ts.nodeType(child);
        if (std.mem.eql(u8, ctype, "identifier")) {
            if (block_type == null) {
                block_type = ts.nodeText(child, source);
            }
        } else if (std.mem.eql(u8, ctype, "string_lit")) {
            if (label == null) {
                const text = ts.nodeText(child, source);
                if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
                    label = text[1 .. text.len - 1];
                } else {
                    label = text;
                }
            }
        }
    }

    if (block_type != null and label != null) {
        return .{ .block_type = block_type.?, .label = label.? };
    }
    return null;
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

test "JB3001 interpolation-only expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "resource \"aws_instance\" \"web\" {\n  ami = \"${var.ami}\"\n}\n";
    const result = fix(alloc, source, "test.tf", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB3001) found = true;
    }
    try std.testing.expect(found);
}

test "JB3001 fix removes interpolation wrapper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "resource \"aws_instance\" \"web\" {\n  ami = \"${var.ami}\"\n}\n";
    const result = fix(alloc, source, "test.tf", SkipSet{}, false);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "var.ami") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "\"${") == null);
}

test "clean HCL no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "resource \"aws_instance\" \"web\" {\n  ami = var.ami\n}\n";
    const result = fix(alloc, source, "test.tf", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "JB3002 duplicate block labels" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "resource \"aws_instance\" \"web\" {\n  ami = \"abc\"\n}\nresource \"aws_instance\" \"web\" {\n  ami = \"def\"\n}\n";
    const result = fix(alloc, source, "test.tf", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB3002) found = true;
    }
    try std.testing.expect(found);
}
