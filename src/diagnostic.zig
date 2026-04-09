const std = @import("std");

pub const RuleId = enum(u16) {
    // Universal (JB0xxx)
    JB0001 = 1, // Trailing whitespace
    JB0002 = 2, // UTF-8 BOM
    JB0003 = 3, // Zero-width characters
    JB0004 = 4, // Bidi overrides
    JB0005 = 5, // Non-breaking space
    JB0006 = 6, // Homoglyph characters
    JB0007 = 7, // Missing trailing newline
    JB0008 = 8, // Mixed line endings
    JB0009 = 9, // Null bytes
    JB0010 = 10, // Smart quotes
    JB0011 = 11, // Invalid UTF-8

    // Bash (JB1xxx)
    JB1001 = 1001,
    JB1002 = 1002,
    JB1003 = 1003,
    JB1004 = 1004,
    JB1005 = 1005,

    // Python (JB2xxx)
    JB2001 = 2001,
    JB2002 = 2002,
    JB2003 = 2003,

    // HCL (JB3xxx)
    JB3001 = 3001,
    JB3002 = 3002,

    // JSON (JB4xxx)
    JB4001 = 4001,
    JB4002 = 4002,

    // YAML (JB5xxx)
    JB5001 = 5001,
    JB5002 = 5002,

    pub fn code(self: RuleId) u16 {
        return @intFromEnum(self);
    }

    pub fn name(self: RuleId) []const u8 {
        return switch (self) {
            .JB0001 => "JB0001",
            .JB0002 => "JB0002",
            .JB0003 => "JB0003",
            .JB0004 => "JB0004",
            .JB0005 => "JB0005",
            .JB0006 => "JB0006",
            .JB0007 => "JB0007",
            .JB0008 => "JB0008",
            .JB0009 => "JB0009",
            .JB0010 => "JB0010",
            .JB0011 => "JB0011",
            .JB1001 => "JB1001",
            .JB1002 => "JB1002",
            .JB1003 => "JB1003",
            .JB1004 => "JB1004",
            .JB1005 => "JB1005",
            .JB2001 => "JB2001",
            .JB2002 => "JB2002",
            .JB2003 => "JB2003",
            .JB3001 => "JB3001",
            .JB3002 => "JB3002",
            .JB4001 => "JB4001",
            .JB4002 => "JB4002",
            .JB5001 => "JB5001",
            .JB5002 => "JB5002",
        };
    }

    pub fn description(self: RuleId) []const u8 {
        return switch (self) {
            .JB0001 => "Trailing whitespace",
            .JB0002 => "UTF-8 BOM",
            .JB0003 => "Zero-width character",
            .JB0004 => "Bidi override character",
            .JB0005 => "Non-breaking space",
            .JB0006 => "Homoglyph character",
            .JB0007 => "Missing trailing newline",
            .JB0008 => "Mixed line endings",
            .JB0009 => "Null byte",
            .JB0010 => "Smart quote",
            .JB0011 => "Invalid UTF-8 sequence",
            .JB1001 => "Unquoted variable expansion",
            .JB1002 => "Unquoted command substitution",
            .JB1003 => "Legacy backtick syntax",
            .JB1004 => "cd without error handling",
            .JB1005 => "Unquoted $@",
            .JB2001 => "Bare except clause",
            .JB2002 => "Equality comparison with None",
            .JB2003 => "Equality comparison with True/False",
            .JB3001 => "Deprecated interpolation-only expression",
            .JB3002 => "Duplicate block labels",
            .JB4001 => "Duplicate keys",
            .JB4002 => "Trailing comma",
            .JB5001 => "Ambiguous truthy string",
            .JB5002 => "Duplicate keys",
        };
    }

    pub fn category(self: RuleId) Category {
        return switch (self) {
            .JB0001, .JB0007, .JB0008 => .format,
            else => .lint,
        };
    }

    pub fn fixable(self: RuleId) bool {
        return switch (self) {
            .JB0001, .JB0002, .JB0003, .JB0004, .JB0005, .JB0007, .JB0008, .JB0010 => true,
            .JB0006, .JB0009, .JB0011 => false,
            .JB1001, .JB1002, .JB1003, .JB1004, .JB1005 => true,
            .JB2001, .JB2002, .JB2003 => true,
            .JB3001 => true,
            .JB3002 => false,
            .JB4001 => false,
            .JB4002 => true,
            .JB5001 => true,
            .JB5002 => false,
        };
    }
};

pub const Category = enum {
    lint,
    format,
};

pub const Diagnostic = struct {
    rule: RuleId,
    line: u32,
    col: u32,
    message: []const u8,
    suggestion: ?[]const u8 = null,
    span_len: u32 = 0,
};

pub const DiagnosticList = struct {
    items: std.ArrayList(Diagnostic) = .empty,

    pub fn add(self: *DiagnosticList, allocator: std.mem.Allocator, diag: Diagnostic) !void {
        try self.items.append(allocator, diag);
    }

    pub fn count(self: DiagnosticList) usize {
        return self.items.items.len;
    }

    pub fn slice(self: DiagnosticList) []const Diagnostic {
        return self.items.items;
    }

    pub fn fixableCount(self: DiagnosticList) usize {
        var n: usize = 0;
        for (self.items.items) |d| {
            if (d.rule.fixable()) n += 1;
        }
        return n;
    }
};

pub const SkipSet = struct {
    skip_lint: bool = false,
    skip_format: bool = false,
    rule_codes: [32]u16 = [_]u16{0} ** 32,
    rule_count: u8 = 0,

    pub fn shouldSkip(self: SkipSet, rule: RuleId) bool {
        if (self.skip_lint and rule.category() == .lint) return true;
        if (self.skip_format and rule.category() == .format) return true;
        const c = rule.code();
        for (self.rule_codes[0..self.rule_count]) |rc| {
            if (rc == c) return true;
        }
        return false;
    }

    pub fn addRule(self: *SkipSet, c: u16) void {
        if (self.rule_count < 32) {
            self.rule_codes[self.rule_count] = c;
            self.rule_count += 1;
        }
    }

    pub fn parse(skip_str: []const u8) SkipSet {
        var set = SkipSet{};
        var iter = std.mem.splitScalar(u8, skip_str, ',');
        while (iter.next()) |token| {
            const trimmed = std.mem.trim(u8, token, " ");
            if (trimmed.len == 0) continue;
            if (std.mem.eql(u8, trimmed, "lint")) {
                set.skip_lint = true;
            } else if (std.mem.eql(u8, trimmed, "format")) {
                set.skip_format = true;
            } else if (trimmed.len >= 3 and std.mem.startsWith(u8, trimmed, "JB")) {
                if (std.fmt.parseInt(u16, trimmed[2..], 10)) |c| {
                    set.addRule(c);
                } else |_| {}
            }
        }
        return set;
    }
};

pub const FixResult = struct {
    output: []const u8,
    diagnostics: []const Diagnostic,
    changed: bool,
};

test "RuleId basics" {
    const rule = RuleId.JB0001;
    try std.testing.expectEqual(@as(u16, 1), rule.code());
    try std.testing.expectEqualStrings("JB0001", rule.name());
    try std.testing.expectEqual(Category.format, rule.category());
    try std.testing.expect(rule.fixable());
}

test "SkipSet parse" {
    const set = SkipSet.parse("lint,JB0001");
    try std.testing.expect(set.skip_lint);
    try std.testing.expect(!set.skip_format);
    try std.testing.expect(set.shouldSkip(RuleId.JB0001));
    try std.testing.expect(set.shouldSkip(RuleId.JB4001));
    try std.testing.expect(!set.shouldSkip(RuleId.JB0007));
}
