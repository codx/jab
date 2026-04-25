const std = @import("std");

pub const RuleId = enum(u16) {
    // Universal
    trailing_whitespace = 1,
    utf8_bom = 2,
    zero_width = 3,
    bidi_override = 4,
    nbsp = 5,
    homoglyph = 6,
    missing_newline = 7,
    mixed_line_endings = 8,
    null_byte = 9,
    smart_quote = 10,
    invalid_utf8 = 11,
    junk_file = 12,
    secret = 13,
    large_file = 14,

    // Bash
    bash_unquoted_var = 1001,
    bash_unquoted_cmd_sub = 1002,
    bash_backtick = 1003,
    bash_cd_no_check = 1004,
    bash_unquoted_at = 1005,
    bash_read_no_r = 1006,
    bash_local_mask_return = 1007,
    bash_test_double_eq = 1008,
    bash_dollar_question = 1009,
    bash_test_and_or = 1010,

    // Python
    py_bare_except = 2001,
    py_none_equality = 2002,
    py_bool_equality = 2003,

    // HCL
    hcl_deprecated_interp = 3001,
    hcl_dup_labels = 3002,

    // JSON
    json_dup_keys = 4001,
    json_trailing_comma = 4002,

    // YAML
    yaml_truthy_string = 5001,
    yaml_dup_keys = 5002,

    // TOML
    toml_dup_keys = 7001,
    toml_dup_table = 7002,

    // Markdown
    md_heading_increment = 6001,
    md_no_empty_links = 6003,

    // External tools (--ext only)
    ext_shellcheck = 9001,
    ext_tofu_fmt = 9002,
    ext_yamllint = 9003,
    ext_ruff = 9004,
    ext_ty = 9005,
    ext_hadolint = 9006,
    ext_actionlint = 9007,
    ext_taplo = 9008,
    ext_nixfmt = 9009,

    pub fn code(self: RuleId) u16 {
        return @intFromEnum(self);
    }

    pub fn name(self: RuleId) []const u8 {
        return switch (self) {
            .trailing_whitespace => "trailing-whitespace",
            .utf8_bom => "utf8-bom",
            .zero_width => "zero-width",
            .bidi_override => "bidi-override",
            .nbsp => "nbsp",
            .homoglyph => "homoglyph",
            .missing_newline => "missing-newline",
            .mixed_line_endings => "mixed-line-endings",
            .null_byte => "null-byte",
            .smart_quote => "smart-quote",
            .invalid_utf8 => "invalid-utf8",
            .junk_file => "junk-file",
            .secret => "secret",
            .large_file => "large-file",
            .bash_unquoted_var => "bash/unquoted-var",
            .bash_unquoted_cmd_sub => "bash/unquoted-cmd-sub",
            .bash_backtick => "bash/backtick",
            .bash_cd_no_check => "bash/cd-no-check",
            .bash_unquoted_at => "bash/unquoted-at",
            .bash_read_no_r => "bash/read-no-r",
            .bash_local_mask_return => "bash/local-mask-return",
            .bash_test_double_eq => "bash/test-double-eq",
            .bash_dollar_question => "bash/dollar-question",
            .bash_test_and_or => "bash/test-and-or",
            .py_bare_except => "py/bare-except",
            .py_none_equality => "py/none-equality",
            .py_bool_equality => "py/bool-equality",
            .hcl_deprecated_interp => "hcl/deprecated-interp",
            .hcl_dup_labels => "hcl/dup-labels",
            .json_dup_keys => "json/dup-keys",
            .json_trailing_comma => "json/trailing-comma",
            .yaml_truthy_string => "yaml/truthy-string",
            .yaml_dup_keys => "yaml/dup-keys",
            .toml_dup_keys => "toml/dup-keys",
            .toml_dup_table => "toml/dup-table",
            .md_heading_increment => "md/heading-increment",
            .md_no_empty_links => "md/no-empty-links",
            .ext_shellcheck => "shellcheck",
            .ext_tofu_fmt => "tofu-fmt",
            .ext_yamllint => "yamllint",
            .ext_ruff => "ruff",
            .ext_ty => "ty",
            .ext_hadolint => "hadolint",
            .ext_actionlint => "actionlint",
            .ext_taplo => "taplo",
            .ext_nixfmt => "nixfmt",
        };
    }

    pub fn fromName(s: []const u8) ?RuleId {
        const fields = @typeInfo(RuleId).@"enum".fields;
        inline for (fields) |f| {
            const rule: RuleId = @enumFromInt(f.value);
            if (std.mem.eql(u8, s, rule.name())) return rule;
        }
        return null;
    }

    pub fn description(self: RuleId) []const u8 {
        return switch (self) {
            .trailing_whitespace => "Trailing whitespace",
            .utf8_bom => "UTF-8 BOM",
            .zero_width => "Zero-width character",
            .bidi_override => "Bidi override character",
            .nbsp => "Non-breaking space",
            .homoglyph => "Homoglyph character",
            .missing_newline => "Missing trailing newline",
            .mixed_line_endings => "Mixed line endings",
            .null_byte => "Null byte",
            .smart_quote => "Smart quote",
            .invalid_utf8 => "Invalid UTF-8 sequence",
            .junk_file => "OS/editor junk file",
            .secret => "Possible secret/credential",
            .large_file => "Large file",
            .bash_unquoted_var => "Unquoted variable expansion",
            .bash_unquoted_cmd_sub => "Unquoted command substitution",
            .bash_backtick => "Legacy backtick syntax",
            .bash_cd_no_check => "cd without error handling",
            .bash_unquoted_at => "Unquoted $@",
            .bash_read_no_r => "read without -r",
            .bash_local_mask_return => "local assignment masks return value",
            .bash_test_double_eq => "== in [ ] test (not POSIX)",
            .bash_dollar_question => "Comparing $? instead of using direct if",
            .bash_test_and_or => "-a/-o in [ ] test (not POSIX)",
            .py_bare_except => "Bare except clause",
            .py_none_equality => "Equality comparison with None",
            .py_bool_equality => "Equality comparison with True/False",
            .hcl_deprecated_interp => "Deprecated interpolation-only expression",
            .hcl_dup_labels => "Duplicate block labels",
            .json_dup_keys => "Duplicate keys",
            .json_trailing_comma => "Trailing comma",
            .yaml_truthy_string => "Ambiguous truthy string",
            .yaml_dup_keys => "Duplicate keys",
            .toml_dup_keys => "Duplicate key",
            .toml_dup_table => "Duplicate table header",
            .md_heading_increment => "Heading level skipped",
            .md_no_empty_links => "Empty link destination",
            .ext_shellcheck => "shellcheck diagnostic",
            .ext_tofu_fmt => "tofu fmt diagnostic",
            .ext_yamllint => "yamllint diagnostic",
            .ext_ruff => "ruff diagnostic",
            .ext_ty => "ty type error",
            .ext_hadolint => "hadolint diagnostic",
            .ext_actionlint => "actionlint diagnostic",
            .ext_taplo => "taplo fmt diagnostic",
            .ext_nixfmt => "nixfmt diagnostic",
        };
    }

    pub fn category(self: RuleId) Category {
        return switch (self) {
            .trailing_whitespace, .missing_newline, .mixed_line_endings, .ext_tofu_fmt, .ext_taplo, .ext_nixfmt => .format,
            else => .lint,
        };
    }

    pub fn fixable(self: RuleId) bool {
        return switch (self) {
            .trailing_whitespace, .utf8_bom, .zero_width, .bidi_override, .nbsp, .missing_newline, .mixed_line_endings, .smart_quote => true,
            .homoglyph, .null_byte, .invalid_utf8, .junk_file, .secret, .large_file => false,
            .bash_unquoted_var, .bash_unquoted_cmd_sub, .bash_backtick, .bash_cd_no_check, .bash_unquoted_at, .bash_test_double_eq => true,
            .bash_read_no_r, .bash_local_mask_return, .bash_dollar_question, .bash_test_and_or => false,
            .py_bare_except, .py_none_equality, .py_bool_equality => true,
            .hcl_deprecated_interp => true,
            .hcl_dup_labels => false,
            .json_dup_keys => false,
            .json_trailing_comma => true,
            .yaml_truthy_string => true,
            .yaml_dup_keys => false,
            .toml_dup_keys => false,
            .toml_dup_table => false,
            .md_heading_increment => false,
            .md_no_empty_links => false,
            .ext_shellcheck => true,
            .ext_tofu_fmt => true,
            .ext_yamllint => false,
            .ext_ruff => true,
            .ext_ty => false,
            .ext_hadolint => false,
            .ext_actionlint => false,
            .ext_taplo => true,
            .ext_nixfmt => true,
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
    /// When set, renderers use this instead of rule.name() (e.g. "SC2086")
    display_name: ?[]const u8 = null,

    pub fn displayName(self: Diagnostic) []const u8 {
        return self.display_name orelse self.rule.name();
    }
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

/// Groups for --skip: "bash", "py", "hcl", "json", "yaml", "md", "ext"
const GroupRange = struct { lo: u16, hi: u16 };
const skip_groups = [_]struct { name: []const u8, range: GroupRange }{
    .{ .name = "bash", .range = .{ .lo = 1001, .hi = 1999 } },
    .{ .name = "py", .range = .{ .lo = 2001, .hi = 2999 } },
    .{ .name = "hcl", .range = .{ .lo = 3001, .hi = 3999 } },
    .{ .name = "json", .range = .{ .lo = 4001, .hi = 4999 } },
    .{ .name = "yaml", .range = .{ .lo = 5001, .hi = 5999 } },
    .{ .name = "toml", .range = .{ .lo = 7001, .hi = 7999 } },
    .{ .name = "md", .range = .{ .lo = 6001, .hi = 6999 } },
    .{ .name = "ext", .range = .{ .lo = 9001, .hi = 9999 } },
};

pub const SkipSet = struct {
    skip_lint: bool = false,
    skip_format: bool = false,
    rule_codes: [32]u16 = [_]u16{0} ** 32,
    rule_count: u8 = 0,
    group_mask: u8 = 0, // bit per group in skip_groups

    pub fn shouldSkip(self: SkipSet, rule: RuleId) bool {
        if (self.skip_lint and rule.category() == .lint) return true;
        if (self.skip_format and rule.category() == .format) return true;
        const c = rule.code();
        // Check group skips
        inline for (skip_groups, 0..) |g, i| {
            if (self.group_mask & (@as(u8, 1) << @intCast(i)) != 0) {
                if (c >= g.range.lo and c <= g.range.hi) return true;
            }
        }
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
                continue;
            }
            if (std.mem.eql(u8, trimmed, "format")) {
                set.skip_format = true;
                continue;
            }
            // Check group names (bash, py, hcl, json, yaml, ext)
            var matched_group = false;
            inline for (skip_groups, 0..) |g, i| {
                if (std.mem.eql(u8, trimmed, g.name)) {
                    set.group_mask |= @as(u8, 1) << @intCast(i);
                    matched_group = true;
                }
            }
            if (matched_group) continue;
            // Try rule name lookup
            if (RuleId.fromName(trimmed)) |rule| {
                set.addRule(rule.code());
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
    const rule = RuleId.trailing_whitespace;
    try std.testing.expectEqual(@as(u16, 1), rule.code());
    try std.testing.expectEqualStrings("trailing-whitespace", rule.name());
    try std.testing.expectEqual(Category.format, rule.category());
    try std.testing.expect(rule.fixable());
}

test "RuleId fromName" {
    try std.testing.expectEqual(RuleId.secret, RuleId.fromName("secret").?);
    try std.testing.expectEqual(RuleId.bash_backtick, RuleId.fromName("bash/backtick").?);
    try std.testing.expectEqual(@as(?RuleId, null), RuleId.fromName("nonexistent"));
}

test "SkipSet parse names" {
    const set = SkipSet.parse("lint,trailing-whitespace");
    try std.testing.expect(set.skip_lint);
    try std.testing.expect(!set.skip_format);
    try std.testing.expect(set.shouldSkip(RuleId.trailing_whitespace));
    try std.testing.expect(set.shouldSkip(RuleId.json_dup_keys)); // lint category
    try std.testing.expect(!set.shouldSkip(RuleId.missing_newline)); // format, not skipped
}

test "SkipSet parse group" {
    const set = SkipSet.parse("bash");
    try std.testing.expect(set.shouldSkip(RuleId.bash_unquoted_var));
    try std.testing.expect(set.shouldSkip(RuleId.bash_backtick));
    try std.testing.expect(!set.shouldSkip(RuleId.py_bare_except));
    try std.testing.expect(!set.shouldSkip(RuleId.trailing_whitespace));
}
