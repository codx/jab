const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const RuleId = diagnostic.RuleId;
const Diagnostic = diagnostic.Diagnostic;
const DiagnosticList = diagnostic.DiagnosticList;
const SkipSet = diagnostic.SkipSet;
const FixResult = diagnostic.FixResult;

const truthy_words = [_][]const u8{
    "yes", "no", "on", "off",
    "Yes", "No", "On", "Off",
    "YES", "NO", "ON", "OFF",
    "y", "n", "Y", "N",
};

pub fn fix(
    allocator: std.mem.Allocator,
    source: []const u8,
    _: []const u8,
    skip: SkipSet,
    dry_run: bool,
) FixResult {
    var diags: DiagnosticList = .{};
    var replacements: std.ArrayList(Replacement) = .empty;

    var line_num: u32 = 1;
    var i: usize = 0;

    var key_tracker: [32]IndentKeys = undefined;
    for (&key_tracker) |*k| k.* = IndentKeys{};
    var max_indent_seen: u32 = 0;

    while (i < source.len) {
        const line_start = i;
        const line_end = findLineEnd(source, i);
        const line = source[line_start..line_end];

        if (!isCommentOrEmpty(line)) {
            const indent = countIndent(line);

            if (indent <= max_indent_seen) {
                var lvl: u32 = indent + 1;
                while (lvl <= max_indent_seen) : (lvl += 1) {
                    if (lvl < 32) key_tracker[lvl] = IndentKeys{};
                }
            }
            if (indent > max_indent_seen) max_indent_seen = indent;

            if (parseKeyValue(line)) |kv| {
                if (!skip.shouldSkip(.yaml_dup_keys) and indent < 32) {
                    if (key_tracker[indent].isDuplicate(kv.key)) {
                        const col: u32 = indent + 1;
                        diags.add(allocator, .{
                            .rule = .yaml_dup_keys,
                            .line = line_num,
                            .col = col,
                            .message = "Duplicate key",
                            .span_len = @intCast(kv.key.len),
                        }) catch {};
                    }
                    key_tracker[indent].add(allocator, kv.key);
                }

                if (!skip.shouldSkip(.yaml_truthy_string)) {
                    const val = std.mem.trim(u8, kv.value, " \t");
                    if (isTruthyWord(val)) {
                        const val_offset = line_start + (kv.value_offset);
                        const trimmed_start = val_offset + @as(usize, @intCast(offsetToTrimmed(kv.value, val)));
                        const col: u32 = @intCast(trimmed_start - line_start + 1);
                        const replacement_text = truthyReplacement(val);
                        diags.add(allocator, .{
                            .rule = .yaml_truthy_string,
                            .line = line_num,
                            .col = col,
                            .message = "Ambiguous truthy string",
                            .span_len = @intCast(val.len),
                            .suggestion = replacement_text,
                        }) catch {};
                        replacements.append(allocator, .{
                            .start = @intCast(trimmed_start),
                            .end = @intCast(trimmed_start + val.len),
                            .text = replacement_text,
                        }) catch {};
                    }
                }
            }
        }

        line_num += 1;
        i = if (line_end < source.len) line_end + 1 else source.len;
    }

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

const KeyValue = struct {
    key: []const u8,
    value: []const u8,
    value_offset: usize,
};

fn parseKeyValue(line: []const u8) ?KeyValue {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    if (trimmed.len == 0 or trimmed[0] == '#' or trimmed[0] == '-') return null;

    const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':') orelse return null;
    if (colon_pos == 0) return null;

    const key = trimmed[0..colon_pos];
    for (key) |c| {
        if (c == ' ' and colon_pos > 0) continue;
        if (c == '#') return null;
    }

    if (colon_pos + 1 >= trimmed.len) return null;
    if (trimmed[colon_pos + 1] != ' ' and trimmed[colon_pos + 1] != '\t') return null;

    const indent_len = line.len - trimmed.len;
    const value_start = indent_len + colon_pos + 1;
    const value = trimmed[colon_pos + 1 ..];

    return .{
        .key = key,
        .value = value,
        .value_offset = value_start,
    };
}

fn isTruthyWord(val: []const u8) bool {
    if (val.len == 0) return false;
    if (val[0] == '"' or val[0] == '\'') return false;
    for (truthy_words) |tw| {
        if (std.mem.eql(u8, val, tw)) return true;
    }
    return false;
}

fn truthyReplacement(val: []const u8) []const u8 {
    if (std.mem.eql(u8, val, "yes") or std.mem.eql(u8, val, "Yes") or
        std.mem.eql(u8, val, "YES") or std.mem.eql(u8, val, "y") or
        std.mem.eql(u8, val, "Y") or std.mem.eql(u8, val, "on") or
        std.mem.eql(u8, val, "On") or std.mem.eql(u8, val, "ON"))
    {
        return "true";
    }
    return "false";
}

fn offsetToTrimmed(raw: []const u8, trimmed: []const u8) u32 {
    return @intCast(@intFromPtr(trimmed.ptr) - @intFromPtr(raw.ptr));
}

fn findLineEnd(source: []const u8, start: usize) usize {
    var pos = start;
    while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
    return pos;
}

fn countIndent(line: []const u8) u32 {
    var n: u32 = 0;
    for (line) |c| {
        if (c == ' ') {
            n += 1;
        } else if (c == '\t') {
            n += 2;
        } else break;
    }
    return n;
}

fn isCommentOrEmpty(line: []const u8) bool {
    const trimmed = std.mem.trimLeft(u8, line, " \t");
    return trimmed.len == 0 or trimmed[0] == '#' or (trimmed.len >= 3 and std.mem.eql(u8, trimmed[0..3], "---"));
}

const IndentKeys = struct {
    keys: [64][]const u8 = undefined,
    count: usize = 0,

    fn isDuplicate(self: *const IndentKeys, key: []const u8) bool {
        for (self.keys[0..self.count]) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    fn add(self: *IndentKeys, allocator: std.mem.Allocator, key: []const u8) void {
        if (self.count < 64) {
            self.keys[self.count] = allocator.dupe(u8, key) catch return;
            self.count += 1;
        }
    }
};

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

test "JB5001 truthy string detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "enabled: yes\nverbose: no\n";
    const result = fix(alloc, source, "test.yaml", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 2), result.diagnostics.len);
    try std.testing.expectEqual(RuleId.yaml_truthy_string, result.diagnostics[0].rule);
}

test "JB5001 fix replaces truthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "enabled: yes\n";
    const result = fix(alloc, source, "test.yaml", SkipSet{}, false);
    try std.testing.expectEqualStrings("enabled: true\n", result.output);
    try std.testing.expect(result.changed);
}

test "JB5001 quoted values are clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "name: \"yes\"\nother: 'no'\n";
    const result = fix(alloc, source, "test.yaml", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "JB5002 duplicate keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "name: foo\nage: 30\nname: bar\n";
    const result = fix(alloc, source, "test.yaml", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .yaml_dup_keys) found = true;
    }
    try std.testing.expect(found);
}

test "clean YAML no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "name: test\ncount: 42\nenabled: true\n";
    const result = fix(alloc, source, "test.yaml", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
