const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const RuleId = diagnostic.RuleId;

/// Parsed inline suppression: which rules are disabled on which lines.
/// Supports `jab:disable` (all rules) or `jab:disable none-equality,bare-except` (specific rules).
/// A suppression applies to its own line and the next line (so you can place it above).
pub const Suppressions = struct {
    /// Each entry: line number (1-indexed) where `jab:disable` appears.
    entries: []const Entry,

    pub const Entry = struct {
        line: u32,
        /// null = suppress all rules on this line
        rules: ?[]const u16,
    };

    /// Returns true if the given rule should be suppressed on the given line.
    /// Checks if `jab:disable` appears on `line` itself or on `line - 1` (the line above).
    pub fn isSuppressed(self: Suppressions, line: u32, rule: RuleId) bool {
        const code = rule.code();
        for (self.entries) |entry| {
            // Suppression on same line or the line above
            if (entry.line == line or entry.line + 1 == line) {
                if (entry.rules) |rules| {
                    for (rules) |r| {
                        if (r == code) return true;
                    }
                } else {
                    return true; // jab:disable with no args = suppress all
                }
            }
        }
        return false;
    }
};

const disable_marker = "jab:disable";

/// Scan source for `jab:disable` comments. Language-agnostic: just looks for the
/// marker string on each line. Works in any comment syntax (#, //, <!-- -->).
pub fn parse(allocator: std.mem.Allocator, source: []const u8) Suppressions {
    var entries: std.ArrayList(Suppressions.Entry) = .empty;
    var line_num: u32 = 1;
    var i: usize = 0;

    while (i < source.len) {
        const line_start = i;
        // Find end of line
        while (i < source.len and source[i] != '\n') : (i += 1) {}
        const line = source[line_start..i];

        if (std.mem.indexOf(u8, line, disable_marker)) |pos| {
            const after = line[pos + disable_marker.len ..];
            const rules = parseRuleList(allocator, after);
            entries.append(allocator, .{
                .line = line_num,
                .rules = rules,
            }) catch {};
        }

        if (i < source.len) i += 1; // skip \n
        line_num += 1;
    }

    return .{ .entries = entries.items };
}

/// Parse rule names after `jab:disable`. Expects optional whitespace then
/// comma-separated rule names (e.g. `none-equality,bare-except`).
/// Returns null if no valid names found (= disable all).
fn parseRuleList(allocator: std.mem.Allocator, text: []const u8) ?[]const u16 {
    const trimmed = std.mem.trim(u8, text, " \t");

    // Handle HTML comment end: strip trailing `-->`
    const cleaned = blk: {
        if (std.mem.endsWith(u8, trimmed, "-->")) {
            break :blk std.mem.trim(u8, trimmed[0 .. trimmed.len - 3], " \t");
        }
        break :blk trimmed;
    };

    if (cleaned.len == 0) return null;

    var codes: std.ArrayList(u16) = .empty;
    var iter = std.mem.splitScalar(u8, cleaned, ',');
    while (iter.next()) |token| {
        const t = std.mem.trim(u8, token, " \t");
        if (t.len == 0) continue;
        if (resolveRule(t)) |code| {
            codes.append(allocator, code) catch {};
        }
    }

    if (codes.items.len == 0) return null;
    return codes.items;
}

/// Resolve a rule identifier to its code. Accepts:
/// - Rule name: "none-equality", "py/none-equality", "trailing-whitespace"
/// - Short name without prefix: "none-equality" matches "py/none-equality"
fn resolveRule(s: []const u8) ?u16 {
    // Try exact match first (e.g. "py/none-equality")
    if (RuleId.fromName(s)) |rule| return rule.code();

    // Try short name: match against suffix after "/" in rule names
    const fields = @typeInfo(RuleId).@"enum".fields;
    inline for (fields) |f| {
        const rule: RuleId = @enumFromInt(f.value);
        const full_name = rule.name();
        if (std.mem.indexOf(u8, full_name, "/")) |slash| {
            const short = full_name[slash + 1 ..];
            if (std.mem.eql(u8, s, short)) return rule.code();
        }
    }

    return null;
}

// --- Tests ---

test "parse empty source" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "");
    try std.testing.expectEqual(@as(usize, 0), s.entries.len);
}

test "parse no suppressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "hello\nworld\n");
    try std.testing.expectEqual(@as(usize, 0), s.entries.len);
}

test "parse disable all on line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "x = 1  # jab:disable\ny = 2\n");
    try std.testing.expectEqual(@as(usize, 1), s.entries.len);
    try std.testing.expectEqual(@as(u32, 1), s.entries[0].line);
    try std.testing.expectEqual(@as(?[]const u16, null), s.entries[0].rules);
    // Same line suppressed
    try std.testing.expect(s.isSuppressed(1, .trailing_whitespace));
    // Next line also suppressed (line-above rule)
    try std.testing.expect(s.isSuppressed(2, .trailing_whitespace));
    // Two lines below: not suppressed
    try std.testing.expect(!s.isSuppressed(3, .trailing_whitespace));
}

test "parse disable with full rule name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "# jab:disable py/bare-except,py/none-equality\nx = None\n");
    try std.testing.expectEqual(@as(usize, 1), s.entries.len);
    try std.testing.expect(s.entries[0].rules != null);
    try std.testing.expectEqual(@as(usize, 2), s.entries[0].rules.?.len);
    try std.testing.expect(s.isSuppressed(2, .py_bare_except));
    try std.testing.expect(s.isSuppressed(2, .py_none_equality));
    try std.testing.expect(!s.isSuppressed(2, .py_bool_equality));
}

test "parse disable with short rule name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "# jab:disable bare-except,none-equality\nx = None\n");
    try std.testing.expectEqual(@as(usize, 1), s.entries.len);
    try std.testing.expect(s.isSuppressed(2, .py_bare_except));
    try std.testing.expect(s.isSuppressed(2, .py_none_equality));
    try std.testing.expect(!s.isSuppressed(2, .py_bool_equality));
}

test "parse same-line disable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "x = None  # jab:disable none-equality\n");
    try std.testing.expect(s.isSuppressed(1, .py_none_equality));
    try std.testing.expect(!s.isSuppressed(1, .py_bare_except));
}

test "parse HTML comment style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "<!-- jab:disable heading-increment -->\n# Bad heading\n");
    try std.testing.expect(s.isSuppressed(2, .md_heading_increment));
}

test "parse HCL comment style" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "// jab:disable deprecated-interp\nname = \"${var.x}\"\n");
    try std.testing.expect(s.isSuppressed(2, .hcl_deprecated_interp));
}

test "parse universal rule name" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const s = parse(arena.allocator(), "# jab:disable trailing-whitespace\nhello   \n");
    try std.testing.expect(s.isSuppressed(2, .trailing_whitespace));
}
