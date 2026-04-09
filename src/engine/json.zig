const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const indent_mod = @import("../indent.zig");
const RuleId = diagnostic.RuleId;
const Diagnostic = diagnostic.Diagnostic;
const DiagnosticList = diagnostic.DiagnosticList;
const SkipSet = diagnostic.SkipSet;
const FixResult = diagnostic.FixResult;

pub fn fix(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    skip: SkipSet,
    dry_run: bool,
) FixResult {
    var diags: DiagnosticList = .{};
    const is_jsonc = std.mem.endsWith(u8, path, ".jsonc");

    // JB4002: Detect trailing commas (not an error in .jsonc)
    const trailing_comma_positions = detectTrailingCommas(allocator, source);
    if (trailing_comma_positions.len > 0 and !is_jsonc) {
        for (trailing_comma_positions) |pos| {
            if (!skip.shouldSkip(.JB4002)) {
                const loc = lineCol(source, pos);
                diags.add(allocator, .{
                    .rule = .JB4002,
                    .line = loc.line,
                    .col = loc.col,
                    .message = "Trailing comma",
                    .span_len = 1,
                    .suggestion = "Remove trailing comma",
                }) catch {};
            }
        }
    }

    // Strip trailing commas for validation/formatting (always, to parse)
    const clean_source = if (trailing_comma_positions.len > 0 and !is_jsonc)
        stripTrailingCommas(allocator, source, trailing_comma_positions)
    else
        source;

    // JB4001: Duplicate key detection via dual-parse
    if (!skip.shouldSkip(.JB4001)) {
        detectDuplicateKeys(allocator, clean_source, &diags);
    }

    // Validate JSON
    const valid = if (std.json.parseFromSlice(std.json.Value, allocator, clean_source, .{
        .duplicate_field_behavior = .use_first,
    })) |_| true else |_| false;

    if (!valid) {
        diags.add(allocator, .{
            .rule = .JB4001,
            .line = 1,
            .col = 1,
            .message = "Invalid JSON syntax",
        }) catch {};
    }

    if (dry_run) {
        return .{
            .output = source,
            .diagnostics = diags.slice(),
            .changed = false,
        };
    }

    // Fix mode: strip trailing commas + reformat
    if (valid) {
        const formatted = formatJson(allocator, clean_source, source);
        if (formatted) |output| {
            return .{
                .output = output,
                .diagnostics = diags.slice(),
                .changed = !std.mem.eql(u8, output, source),
            };
        }
    }

    // Fallback: just strip commas if we had them
    if (trailing_comma_positions.len > 0 and !is_jsonc) {
        const output = ensureTrailingNewline(allocator, clean_source);
        return .{
            .output = output,
            .diagnostics = diags.slice(),
            .changed = !std.mem.eql(u8, output, source),
        };
    }

    return .{
        .output = source,
        .diagnostics = diags.slice(),
        .changed = false,
    };
}

fn formatJson(allocator: std.mem.Allocator, clean_source: []const u8, original: []const u8) ?[]const u8 {
    const style = indent_mod.detect(original);

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, clean_source, .{
        .duplicate_field_behavior = .use_first,
    }) catch return null;

    const opts: std.json.Stringify.Options = switch (style) {
        .tabs => .{ .whitespace = .indent_tab },
        .spaces_4 => .{ .whitespace = .indent_4 },
        else => .{ .whitespace = .indent_2 },
    };

    const json_str = std.json.Stringify.valueAlloc(allocator, parsed.value, opts) catch return null;

    var result: std.ArrayList(u8) = .empty;
    result.appendSlice(allocator, json_str) catch return null;
    result.append(allocator, '\n') catch return null;
    return result.items;
}

fn ensureTrailingNewline(allocator: std.mem.Allocator, source: []const u8) []const u8 {
    if (source.len > 0 and source[source.len - 1] == '\n') return source;
    var result: std.ArrayList(u8) = .empty;
    result.appendSlice(allocator, source) catch return source;
    result.append(allocator, '\n') catch return source;
    return result.items;
}

fn detectTrailingCommas(allocator: std.mem.Allocator, source: []const u8) []usize {
    var positions: std.ArrayList(usize) = .empty;
    var in_string = false;
    var escape = false;
    var last_comma: ?usize = null;

    for (source, 0..) |c, idx| {
        if (escape) {
            escape = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') escape = true;
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '"' => in_string = true,
            ',' => last_comma = idx,
            ']', '}' => {
                if (last_comma) |pos| {
                    var only_ws = true;
                    var j = pos + 1;
                    while (j < idx) : (j += 1) {
                        if (source[j] != ' ' and source[j] != '\t' and source[j] != '\n' and source[j] != '\r') {
                            only_ws = false;
                            break;
                        }
                    }
                    if (only_ws) {
                        positions.append(allocator, pos) catch {};
                    }
                }
                last_comma = null;
            },
            ' ', '\t', '\n', '\r' => {},
            else => last_comma = null,
        }
    }
    return positions.items;
}

fn stripTrailingCommas(allocator: std.mem.Allocator, source: []const u8, positions: []const usize) []const u8 {
    var result: std.ArrayList(u8) = .empty;
    for (source, 0..) |c, idx| {
        var should_skip = false;
        for (positions) |p| {
            if (p == idx) {
                should_skip = true;
                break;
            }
        }
        if (!should_skip) {
            result.append(allocator, c) catch {};
        }
    }
    return result.items;
}

fn detectDuplicateKeys(allocator: std.mem.Allocator, source: []const u8, diags: *DiagnosticList) void {
    // Parse twice: once with use_first, once with @"error" to detect duplicates
    // If @"error" parse fails but use_first succeeds, there are duplicate keys
    const ok_first = if (std.json.parseFromSlice(std.json.Value, allocator, source, .{
        .duplicate_field_behavior = .use_first,
    })) |_| true else |_| false;

    if (!ok_first) return; // invalid JSON, skip duplicate check

    const ok_error = if (std.json.parseFromSlice(std.json.Value, allocator, source, .{
        .duplicate_field_behavior = .@"error",
    })) |_| true else |_| false;

    if (!ok_error) {
        // There are duplicate keys — scan source to find them
        findDuplicateKeyPositions(allocator, source, diags);
    }
}

fn findDuplicateKeyPositions(allocator: std.mem.Allocator, source: []const u8, diags: *DiagnosticList) void {
    // Simple approach: track keys at each nesting depth
    // We scan for string keys in object context
    var depth: u32 = 0;
    var in_string = false;
    var escape = false;
    var in_object_stack: [64]bool = [_]bool{false} ** 64;
    var key_expected = false;
    var after_colon = false;

    // Track seen keys per depth (simple reset on depth change)
    var seen_keys: [64]KeyTracker = undefined;
    for (&seen_keys) |*k| k.* = KeyTracker{};

    var i: usize = 0;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (escape) {
            escape = false;
            continue;
        }
        if (in_string) {
            if (c == '\\') escape = true;
            if (c == '"') in_string = false;
            continue;
        }
        switch (c) {
            '{' => {
                if (depth < 63) {
                    depth += 1;
                    in_object_stack[depth] = true;
                    key_expected = true;
                    after_colon = false;
                    seen_keys[depth] = KeyTracker{};
                }
            },
            '[' => {
                if (depth < 63) {
                    depth += 1;
                    in_object_stack[depth] = false;
                    key_expected = false;
                    after_colon = false;
                }
            },
            '}', ']' => {
                if (depth > 0) depth -= 1;
                key_expected = false;
                after_colon = false;
            },
            ':' => {
                after_colon = true;
                key_expected = false;
            },
            ',' => {
                if (depth > 0 and in_object_stack[depth]) {
                    key_expected = true;
                    after_colon = false;
                }
            },
            '"' => {
                if (depth > 0 and in_object_stack[depth] and key_expected and !after_colon) {
                    // This is a key — extract it
                    const key_start = i + 1;
                    var j = key_start;
                    var esc = false;
                    while (j < source.len) : (j += 1) {
                        if (esc) {
                            esc = false;
                            continue;
                        }
                        if (source[j] == '\\') {
                            esc = true;
                            continue;
                        }
                        if (source[j] == '"') break;
                    }
                    const key = source[key_start..j];
                    if (seen_keys[depth].isDuplicate(key)) {
                        const loc = lineCol(source, i);
                        diags.add(allocator, .{
                            .rule = .JB4001,
                            .line = loc.line,
                            .col = loc.col,
                            .message = "Duplicate key",
                            .span_len = @intCast(key.len + 2),
                        }) catch {};
                    }
                    seen_keys[depth].add(key);
                    in_string = true; // skip past the string content
                } else {
                    in_string = true;
                }
            },
            else => {},
        }
    }
}

const KeyTracker = struct {
    keys: [128][]const u8 = undefined,
    count: usize = 0,

    fn isDuplicate(self: *const KeyTracker, key: []const u8) bool {
        for (self.keys[0..self.count]) |k| {
            if (std.mem.eql(u8, k, key)) return true;
        }
        return false;
    }

    fn add(self: *KeyTracker, key: []const u8) void {
        if (self.count < 128) {
            self.keys[self.count] = key;
            self.count += 1;
        }
    }
};

fn lineCol(source: []const u8, pos: usize) struct { line: u32, col: u32 } {
    var line: u32 = 1;
    var last_nl: usize = 0;
    for (source[0..pos], 0..) |c, idx| {
        if (c == '\n') {
            line += 1;
            last_nl = idx + 1;
        }
    }
    return .{ .line = line, .col = @intCast(pos - last_nl + 1) };
}

test "detect trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "{\"a\": 1, \"b\": 2,}";
    const positions = detectTrailingCommas(alloc, source);
    try std.testing.expectEqual(@as(usize, 1), positions.len);
}

test "fix removes trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "{\"a\": 1, \"b\": 2,}";
    const result = fix(alloc, source, "test.json", SkipSet{}, false);
    var found_bk4002 = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB4002) found_bk4002 = true;
    }
    try std.testing.expect(found_bk4002);
    try std.testing.expect(result.changed);
}

test "valid json no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "{\"a\": 1}\n";
    const result = fix(alloc, source, "test.json", SkipSet{}, true);
    try std.testing.expect(!result.changed);
}

test "detect duplicate keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "{\"a\": 1, \"a\": 2}\n";
    const result = fix(alloc, source, "test.json", SkipSet{}, true);
    var found_dup = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB4001) found_dup = true;
    }
    try std.testing.expect(found_dup);
}

test "dry run does not modify" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "{\"a\": 1, \"b\": 2,}\n";
    const result = fix(alloc, source, "test.json", SkipSet{}, true);
    try std.testing.expect(!result.changed);
    try std.testing.expectEqual(source.ptr, result.output.ptr);
}

test "jsonc allows trailing commas" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "{\"a\": 1,}\n";
    const result = fix(alloc, source, "test.jsonc", SkipSet{}, true);
    var found_bk4002 = false;
    for (result.diagnostics) |d| {
        if (d.rule == .JB4002) found_bk4002 = true;
    }
    try std.testing.expect(!found_bk4002);
}
