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

    // Track table headers for duplicate detection
    var table_tracker: TableTracker = .{};

    // Track keys per current table section
    var key_tracker: KeyTracker = .{};

    while (i < source.len) {
        const line_start = i;
        const line_end = findLineEnd(source, i);
        const line = source[line_start..line_end];
        const trimmed = std.mem.trimLeft(u8, line, " \t");

        if (trimmed.len > 0 and trimmed[0] != '#') {
            // Table header: [table] or [[array]]
            if (parseTableHeader(trimmed)) |header| {
                // Reset key tracker for new section
                key_tracker = .{};

                // JB7002: duplicate table headers
                if (!skip.shouldSkip(.toml_dup_table)) {
                    if (!header.is_array) {
                        if (table_tracker.isDuplicate(header.name)) {
                            const col: u32 = @intCast(line.len - trimmed.len + 1);
                            diags.add(allocator, .{
                                .rule = .toml_dup_table,
                                .line = line_num,
                                .col = col,
                                .message = "Duplicate table header",
                                .span_len = @intCast(header.full_len),
                            }) catch {};
                        }
                        table_tracker.add(allocator, header.name);
                    }
                }
            } else if (parseKey(trimmed)) |key| {
                // JB7001: duplicate keys in same table
                if (!skip.shouldSkip(.toml_dup_keys)) {
                    if (key_tracker.isDuplicate(key)) {
                        const col: u32 = @intCast(line.len - trimmed.len + 1);
                        diags.add(allocator, .{
                            .rule = .toml_dup_keys,
                            .line = line_num,
                            .col = col,
                            .message = "Duplicate key",
                            .span_len = @intCast(key.len),
                        }) catch {};
                    }
                    key_tracker.add(allocator, key);
                }
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

const TableHeader = struct {
    name: []const u8,
    is_array: bool,
    full_len: usize,
};

fn parseTableHeader(trimmed: []const u8) ?TableHeader {
    if (trimmed.len < 3) return null;

    // [[array_of_tables]]
    if (trimmed.len >= 4 and trimmed[0] == '[' and trimmed[1] == '[') {
        const end = std.mem.indexOf(u8, trimmed, "]]") orelse return null;
        return .{
            .name = std.mem.trim(u8, trimmed[2..end], " \t"),
            .is_array = true,
            .full_len = end + 2,
        };
    }

    // [table]
    if (trimmed[0] == '[') {
        const end = std.mem.indexOfScalar(u8, trimmed, ']') orelse return null;
        return .{
            .name = std.mem.trim(u8, trimmed[1..end], " \t"),
            .is_array = false,
            .full_len = end + 1,
        };
    }

    return null;
}

fn parseKey(trimmed: []const u8) ?[]const u8 {
    if (trimmed.len == 0) return null;

    // Quoted key
    if (trimmed[0] == '"' or trimmed[0] == '\'') {
        const quote = trimmed[0];
        const end = std.mem.indexOfScalarPos(u8, trimmed, 1, quote) orelse return null;
        // Must be followed by = (with optional whitespace)
        const after = std.mem.trimLeft(u8, trimmed[end + 1 ..], " \t");
        if (after.len == 0 or after[0] != '=') return null;
        return trimmed[1..end];
    }

    // Bare key
    const eq_pos = std.mem.indexOfScalar(u8, trimmed, '=') orelse return null;
    if (eq_pos == 0) return null;
    return std.mem.trimRight(u8, trimmed[0..eq_pos], " \t");
}

fn findLineEnd(source: []const u8, start: usize) usize {
    var pos = start;
    while (pos < source.len and source[pos] != '\n') : (pos += 1) {}
    return pos;
}

const KeyTracker = struct {
    keys: [64][]const u8 = undefined,
    count: usize = 0,

    fn isDuplicate(self: *const KeyTracker, key: []const u8) bool {
        for (self.keys[0..self.count]) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    fn add(self: *KeyTracker, allocator: std.mem.Allocator, key: []const u8) void {
        if (self.count < 64) {
            self.keys[self.count] = allocator.dupe(u8, key) catch return;
            self.count += 1;
        }
    }
};

const TableTracker = struct {
    tables: [64][]const u8 = undefined,
    count: usize = 0,

    fn isDuplicate(self: *const TableTracker, name: []const u8) bool {
        for (self.tables[0..self.count]) |t| {
            if (std.mem.eql(u8, t, name)) return true;
        }
        return false;
    }

    fn add(self: *TableTracker, allocator: std.mem.Allocator, name: []const u8) void {
        if (self.count < 64) {
            self.tables[self.count] = allocator.dupe(u8, name) catch return;
            self.count += 1;
        }
    }
};

test "JB7001 duplicate keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "name = \"foo\"\nage = 30\nname = \"bar\"\n";
    const result = fix(alloc, source, "test.toml", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .toml_dup_keys) found = true;
    }
    try std.testing.expect(found);
}

test "JB7001 keys in different tables are clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "[server]\nname = \"foo\"\n\n[client]\nname = \"bar\"\n";
    const result = fix(alloc, source, "test.toml", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "JB7002 duplicate table header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "[server]\nhost = \"a\"\n\n[server]\nhost = \"b\"\n";
    const result = fix(alloc, source, "test.toml", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .toml_dup_table) found = true;
    }
    try std.testing.expect(found);
}

test "JB7002 array tables are not duplicates" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "[[products]]\nname = \"a\"\n\n[[products]]\nname = \"b\"\n";
    const result = fix(alloc, source, "test.toml", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}

test "clean TOML no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "[package]\nname = \"jab\"\nversion = \"0.1.0\"\n\n[dependencies]\n";
    const result = fix(alloc, source, "test.toml", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
