const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
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
    _ = dry_run;
    var diags: DiagnosticList = .{};

    var line_num: u32 = 1;
    var i: usize = 0;
    var prev_heading_level: u8 = 0;
    var in_fenced_block = false;

    while (i < source.len) {
        const line_start = i;
        const line_end = findLineEnd(source, i);
        const line = source[line_start..line_end];
        const trimmed = std.mem.trimLeft(u8, line, " ");

        // Track fenced code blocks
        if (trimmed.len >= 3 and std.mem.startsWith(u8, trimmed, "```")) {
            in_fenced_block = !in_fenced_block;
        } else if (!in_fenced_block) {
            // ATX headings
            if (headingLevel(trimmed)) |level| {
                // JB6001: heading increment
                if (!skip.shouldSkip(.md_heading_increment)) {
                    if (prev_heading_level > 0 and level > prev_heading_level + 1) {
                        diags.add(allocator, .{
                            .rule = .md_heading_increment,
                            .line = line_num,
                            .col = 1,
                            .message = "Heading level skipped",
                            .span_len = @intCast(level),
                        }) catch {};
                    }
                }
                prev_heading_level = level;
            }

            // JB6003: empty links [text]()
            if (!skip.shouldSkip(.md_no_empty_links)) {
                checkEmptyLinks(allocator, line, line_start, line_num, &diags);
            }
        }

        line_num += 1;
        i = if (line_end < source.len) line_end + 1 else source.len;
    }

    return .{
        .output = source,
        .diagnostics = diags.slice(),
        .changed = false,
    };
}

fn headingLevel(trimmed: []const u8) ?u8 {
    if (trimmed.len == 0 or trimmed[0] != '#') return null;
    var level: u8 = 0;
    while (level < trimmed.len and trimmed[level] == '#') : (level += 1) {}
    if (level > 6) return null;
    // Must be followed by space or end of line
    if (level < trimmed.len and trimmed[level] != ' ' and trimmed[level] != '\t') return null;
    return level;
}

fn checkEmptyLinks(
    allocator: std.mem.Allocator,
    line: []const u8,
    line_start: usize,
    line_num: u32,
    diags: *DiagnosticList,
) void {
    _ = line_start;
    var pos: usize = 0;
    while (pos < line.len) {
        // Find ](
        const bracket = std.mem.indexOfPos(u8, line, pos, "](") orelse break;
        const paren_start = bracket + 2;
        if (paren_start < line.len and line[paren_start] == ')') {
            // Find the opening [
            const col: u32 = @intCast(bracket + 1); // 0-based to 1-based
            diags.add(allocator, .{
                .rule = .md_no_empty_links,
                .line = line_num,
                .col = col,
                .message = "Empty link destination",
                .span_len = 3, // ]()
            }) catch {};
            pos = paren_start + 1;
        } else {
            pos = bracket + 1;
        }
    }
}

fn findLineEnd(source: []const u8, start: usize) usize {
    var pos = start;
    while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
    return pos;
}

test "JB6001 heading level skip" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "# Title\n### Subsection\n";
    const result = fix(alloc, source, "test.md", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .md_heading_increment) found = true;
    }
    try std.testing.expect(found);
}

test "JB6001 sequential headings are clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "# Title\n## Section\n### Subsection\n";
    const result = fix(alloc, source, "test.md", SkipSet{}, true);
    for (result.diagnostics) |d| {
        if (d.rule == .md_heading_increment) {
            return error.UnexpectedDiagnostic;
        }
    }
}

test "JB6003 empty link" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "Check [this link]() for details\n";
    const result = fix(alloc, source, "test.md", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .md_no_empty_links) found = true;
    }
    try std.testing.expect(found);
}

test "headings inside fenced code blocks are ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "# Title\n```\n### Not a heading\n```\n## Section\n";
    const result = fix(alloc, source, "test.md", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "clean markdown no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "# Title\n\nSome text with [a link](https://example.com).\n\n## Section\n";
    const result = fix(alloc, source, "test.md", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
