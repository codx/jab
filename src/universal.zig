const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const RuleId = diagnostic.RuleId;
const Diagnostic = diagnostic.Diagnostic;
const DiagnosticList = diagnostic.DiagnosticList;
const SkipSet = diagnostic.SkipSet;

pub fn scan(
    allocator: std.mem.Allocator,
    source: []const u8,
    skip: SkipSet,
    dry_run: bool,
) struct { output: []const u8, diagnostics: []const Diagnostic, changed: bool } {
    var diags: DiagnosticList = .{};
    var line: u32 = 1;
    var col: u32 = 1;
    var has_crlf = false;
    var has_lf = false;
    var result: std.ArrayList(u8) = .empty;

    var i: usize = 0;
    while (i < source.len) {
        const b = source[i];

        // JB0009: Null bytes (detect only, not fixable)
        if (b == 0) {
            if (!skip.shouldSkip(.null_byte)) {
                diags.add(allocator, .{ .rule = .null_byte, .line = line, .col = col, .message = "Null byte", .span_len = 1 }) catch {};
            }
            result.append(allocator, b) catch {};
            i += 1;
            col += 1;
            continue;
        }

        // JB0002: UTF-8 BOM
        if (i == 0 and source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
            if (!skip.shouldSkip(.utf8_bom)) {
                diags.add(allocator, .{ .rule = .utf8_bom, .line = 1, .col = 1, .message = "UTF-8 BOM detected", .span_len = 3 }) catch {};
            }
            if (!dry_run) {
                i += 3;
                continue;
            }
            result.appendSlice(allocator, source[0..3]) catch {};
            i += 3;
            col += 3;
            continue;
        }

        // CRLF handling for JB0008
        if (b == '\r' and i + 1 < source.len and source[i + 1] == '\n') {
            has_crlf = true;
            if (!dry_run) {
                i += 1;
                continue;
            }
            result.append(allocator, b) catch {};
            i += 1;
            col += 1;
            continue;
        }

        if (b == '\n') {
            has_lf = true;

            // JB0001: Trailing whitespace
            if (!skip.shouldSkip(.trailing_whitespace)) {
                const line_start = findLineStart(source, i);
                const trimmed_end = trimTrailingWhitespace(source, line_start, i);
                if (trimmed_end < i) {
                    const ws_col: u32 = @intCast(trimmed_end - line_start + 1);
                    const ws_len: u32 = @intCast(i - trimmed_end);
                    diags.add(allocator, .{
                        .rule = .trailing_whitespace,
                        .line = line,
                        .col = ws_col,
                        .message = "Trailing whitespace",
                        .span_len = ws_len,
                    }) catch {};
                    if (!dry_run) {
                        if (result.items.len >= ws_len) {
                            result.items.len -= ws_len;
                        }
                    }
                }
            }

            result.append(allocator, '\n') catch {};
            line += 1;
            col = 1;
            i += 1;
            continue;
        }

        // Multi-byte UTF-8 checks
        if (b >= 0x80) {
            const seq_len = utf8SeqLen(b);
            if (seq_len == 0 or i + seq_len > source.len) {
                if (!skip.shouldSkip(.invalid_utf8)) {
                    diags.add(allocator, .{ .rule = .invalid_utf8, .line = line, .col = col, .message = "Invalid UTF-8 byte sequence", .span_len = 1 }) catch {};
                }
                result.append(allocator, b) catch {};
                i += 1;
                col += 1;
                continue;
            }

            const codepoint = decodeUtf8(source[i..][0..seq_len]);
            if (codepoint) |cp| {
                // JB0003: Zero-width characters
                if (isZeroWidth(cp)) {
                    if (!skip.shouldSkip(.zero_width)) {
                        diags.add(allocator, .{ .rule = .zero_width, .line = line, .col = col, .message = "Zero-width character", .span_len = @intCast(seq_len) }) catch {};
                    }
                    if (!dry_run) {
                        i += seq_len;
                        continue;
                    }
                }

                // JB0004: Bidi overrides
                if (isBidiOverride(cp)) {
                    if (!skip.shouldSkip(.bidi_override)) {
                        diags.add(allocator, .{ .rule = .bidi_override, .line = line, .col = col, .message = "Bidi override character (CVE-2021-42574)", .span_len = @intCast(seq_len) }) catch {};
                    }
                    if (!dry_run) {
                        i += seq_len;
                        continue;
                    }
                }

                // JB0005: Non-breaking space
                if (cp == 0x00A0) {
                    if (!skip.shouldSkip(.nbsp)) {
                        diags.add(allocator, .{ .rule = .nbsp, .line = line, .col = col, .message = "Non-breaking space", .span_len = @intCast(seq_len), .suggestion = "Replace with regular space" }) catch {};
                    }
                    if (!dry_run) {
                        result.append(allocator, ' ') catch {};
                        i += seq_len;
                        col += 1;
                        continue;
                    }
                }

                // JB0006: Homoglyphs
                if (isHomoglyph(cp)) {
                    if (!skip.shouldSkip(.homoglyph)) {
                        diags.add(allocator, .{ .rule = .homoglyph, .line = line, .col = col, .message = "Homoglyph character (Cyrillic mimicking Latin)", .span_len = @intCast(seq_len) }) catch {};
                    }
                }

                // JB0010: Smart quotes
                if (isSmartQuote(cp)) {
                    if (!skip.shouldSkip(.smart_quote)) {
                        const replacement: []const u8 = if (cp == 0x201C or cp == 0x201D) "\"" else "'";
                        diags.add(allocator, .{ .rule = .smart_quote, .line = line, .col = col, .message = "Smart quote", .span_len = @intCast(seq_len), .suggestion = replacement }) catch {};
                    }
                    if (!dry_run) {
                        if (cp == 0x201C or cp == 0x201D) {
                            result.append(allocator, '"') catch {};
                        } else {
                            result.append(allocator, '\'') catch {};
                        }
                        i += seq_len;
                        col += 1;
                        continue;
                    }
                }

                result.appendSlice(allocator, source[i..][0..seq_len]) catch {};
                i += seq_len;
                col += 1;
                continue;
            } else {
                if (!skip.shouldSkip(.invalid_utf8)) {
                    diags.add(allocator, .{ .rule = .invalid_utf8, .line = line, .col = col, .message = "Invalid UTF-8 byte sequence", .span_len = @intCast(seq_len) }) catch {};
                }
                result.appendSlice(allocator, source[i..][0..seq_len]) catch {};
                i += seq_len;
                col += 1;
                continue;
            }
        }

        result.append(allocator, b) catch {};
        i += 1;
        col += 1;
    }

    // JB0001: trailing whitespace on last line (no trailing newline)
    if (!skip.shouldSkip(.trailing_whitespace) and result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
        const last_nl = if (std.mem.lastIndexOfScalar(u8, result.items, '\n')) |p| p + 1 else 0;
        const trimmed_end = trimTrailingWhitespace(result.items, last_nl, result.items.len);
        if (trimmed_end < result.items.len) {
            const ws_len: u32 = @intCast(result.items.len - trimmed_end);
            diags.add(allocator, .{
                .rule = .trailing_whitespace,
                .line = line,
                .col = @intCast(trimmed_end - last_nl + 1),
                .message = "Trailing whitespace",
                .span_len = ws_len,
            }) catch {};
            if (!dry_run) {
                result.items.len = trimmed_end;
            }
        }
    }

    // JB0008: Mixed line endings
    if (has_crlf and has_lf and !skip.shouldSkip(.mixed_line_endings)) {
        diags.add(allocator, .{ .rule = .mixed_line_endings, .line = 1, .col = 1, .message = "Mixed line endings (CRLF + LF)" }) catch {};
    }

    if (dry_run) {
        result.deinit(allocator);
        return .{ .output = source, .diagnostics = diags.slice(), .changed = false };
    }

    const output = result.toOwnedSlice(allocator) catch source;
    const changed = !std.mem.eql(u8, output, source);

    return .{ .output = output, .diagnostics = diags.slice(), .changed = changed };
}

fn findLineStart(source: []const u8, pos: usize) usize {
    if (pos == 0) return 0;
    var p = pos - 1;
    while (p > 0) : (p -= 1) {
        if (source[p] == '\n') return p + 1;
    }
    if (source[0] == '\n') return 1;
    return 0;
}

fn trimTrailingWhitespace(source: []const u8, start: usize, end: usize) usize {
    var e = end;
    while (e > start and (source[e - 1] == ' ' or source[e - 1] == '\t')) {
        e -= 1;
    }
    return e;
}

fn utf8SeqLen(first_byte: u8) usize {
    if (first_byte & 0x80 == 0) return 1;
    if (first_byte & 0xE0 == 0xC0) return 2;
    if (first_byte & 0xF0 == 0xE0) return 3;
    if (first_byte & 0xF8 == 0xF0) return 4;
    return 0;
}

fn decodeUtf8(bytes: []const u8) ?u21 {
    if (bytes.len == 2) {
        return @as(u21, bytes[0] & 0x1F) << 6 | @as(u21, bytes[1] & 0x3F);
    } else if (bytes.len == 3) {
        return @as(u21, bytes[0] & 0x0F) << 12 | @as(u21, bytes[1] & 0x3F) << 6 | @as(u21, bytes[2] & 0x3F);
    } else if (bytes.len == 4) {
        return @as(u21, bytes[0] & 0x07) << 18 | @as(u21, bytes[1] & 0x3F) << 12 | @as(u21, bytes[2] & 0x3F) << 6 | @as(u21, bytes[3] & 0x3F);
    }
    return null;
}

fn isZeroWidth(cp: u21) bool {
    return cp == 0x200B or cp == 0x200C or cp == 0x200D or cp == 0xFEFF;
}

fn isBidiOverride(cp: u21) bool {
    return cp >= 0x202A and cp <= 0x202E;
}

fn isHomoglyph(cp: u21) bool {
    return cp == 0x0430 or cp == 0x0435 or cp == 0x043E or cp == 0x0440 or
        cp == 0x0441 or cp == 0x0410 or cp == 0x0415 or cp == 0x041E or
        cp == 0x0420 or cp == 0x0421;
}

fn isSmartQuote(cp: u21) bool {
    return cp == 0x201C or cp == 0x201D or cp == 0x2018 or cp == 0x2019;
}

// --- JB0013: Secret/credential detection ---

const SecretPattern = struct {
    prefix: []const u8,
    min_suffix: usize, // minimum chars after prefix
    suffix_check: SuffixCheck,
    label: []const u8,

    const SuffixCheck = enum { alnum_upper, alnum, alnum_dash, alnum_underscore, alnum_dash_underscore };
};

const secret_patterns = [_]SecretPattern{
    .{ .prefix = "AKIA", .min_suffix = 16, .suffix_check = .alnum_upper, .label = "AWS access key" },
    .{ .prefix = "ghp_", .min_suffix = 36, .suffix_check = .alnum, .label = "GitHub personal access token" },
    .{ .prefix = "gho_", .min_suffix = 36, .suffix_check = .alnum, .label = "GitHub OAuth token" },
    .{ .prefix = "ghu_", .min_suffix = 36, .suffix_check = .alnum, .label = "GitHub user-to-server token" },
    .{ .prefix = "ghs_", .min_suffix = 36, .suffix_check = .alnum, .label = "GitHub server-to-server token" },
    .{ .prefix = "github_pat_", .min_suffix = 22, .suffix_check = .alnum_underscore, .label = "GitHub fine-grained PAT" },
    .{ .prefix = "glpat-", .min_suffix = 20, .suffix_check = .alnum_dash_underscore, .label = "GitLab PAT" },
    .{ .prefix = "xoxb-", .min_suffix = 10, .suffix_check = .alnum_dash, .label = "Slack bot token" },
    .{ .prefix = "xoxp-", .min_suffix = 10, .suffix_check = .alnum_dash, .label = "Slack user token" },
    .{ .prefix = "xoxo-", .min_suffix = 10, .suffix_check = .alnum_dash, .label = "Slack token" },
    .{ .prefix = "xoxr-", .min_suffix = 10, .suffix_check = .alnum_dash, .label = "Slack token" },
    .{ .prefix = "xoxs-", .min_suffix = 10, .suffix_check = .alnum_dash, .label = "Slack token" },
};

const private_key_marker = "-----BEGIN ";
const private_key_suffix = "PRIVATE KEY-----";

pub fn scanSecrets(
    allocator: std.mem.Allocator,
    source: []const u8,
    skip: SkipSet,
) []const Diagnostic {
    if (skip.shouldSkip(.secret)) return &.{};

    var diags: DiagnosticList = .{};
    var line: u32 = 1;
    var line_start: usize = 0;

    var i: usize = 0;
    while (i < source.len) {
        if (source[i] == '\n') {
            line += 1;
            i += 1;
            line_start = i;
            continue;
        }

        // Check prefix-based patterns
        for (secret_patterns) |pat| {
            if (i + pat.prefix.len + pat.min_suffix <= source.len and
                std.mem.eql(u8, source[i..][0..pat.prefix.len], pat.prefix))
            {
                const after = source[i + pat.prefix.len ..];
                const run = countSuffixRun(after, pat.suffix_check);
                if (run >= pat.min_suffix) {
                    const col: u32 = @intCast(i - line_start + 1);
                    diags.add(allocator, .{
                        .rule = .secret,
                        .line = line,
                        .col = col,
                        .message = pat.label,
                        .span_len = @intCast(pat.prefix.len + run),
                    }) catch {};
                    i += pat.prefix.len + run;
                    break;
                }
            }
        } else {
            // Check for "sk-" pattern (OpenAI/Stripe) — require preceding quote or =
            if (i + 3 + 20 <= source.len and source[i] == 's' and source[i + 1] == 'k' and source[i + 2] == '-') {
                if (i > 0 and (source[i - 1] == '"' or source[i - 1] == '\'' or source[i - 1] == '=')) {
                    const after = source[i + 3 ..];
                    const run = countSuffixRun(after, .alnum_dash_underscore);
                    if (run >= 20) {
                        const col: u32 = @intCast(i - line_start + 1);
                        diags.add(allocator, .{
                            .rule = .secret,
                            .line = line,
                            .col = col,
                            .message = "Possible API secret key (sk-...)",
                            .span_len = @intCast(3 + run),
                        }) catch {};
                        i += 3 + run;
                        continue;
                    }
                }
            }

            // Check for private key markers
            if (i + private_key_marker.len <= source.len and
                std.mem.eql(u8, source[i..][0..private_key_marker.len], private_key_marker))
            {
                // Look for "PRIVATE KEY-----" on the same line
                const line_end = std.mem.indexOfScalarPos(u8, source, i, '\n') orelse source.len;
                const rest = source[i..line_end];
                if (std.mem.indexOf(u8, rest, private_key_suffix) != null) {
                    const col: u32 = @intCast(i - line_start + 1);
                    diags.add(allocator, .{
                        .rule = .secret,
                        .line = line,
                        .col = col,
                        .message = "Private key",
                        .span_len = @intCast(line_end - i),
                    }) catch {};
                    i = line_end;
                    continue;
                }
            }

            i += 1;
            continue;
        }
    }

    return diags.slice();
}

fn countSuffixRun(data: []const u8, check: SecretPattern.SuffixCheck) usize {
    var n: usize = 0;
    while (n < data.len) : (n += 1) {
        const c = data[n];
        const ok = switch (check) {
            .alnum_upper => (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'),
            .alnum => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9'),
            .alnum_dash => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-',
            .alnum_underscore => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_',
            .alnum_dash_underscore => (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '-' or c == '_',
        };
        if (!ok) break;
    }
    return n;
}

test "JB0001 trailing whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scan(alloc, "hello   \nworld\n", SkipSet{}, false);
    try std.testing.expectEqualStrings("hello\nworld\n", r.output);
    try std.testing.expect(r.changed);
    try std.testing.expect(r.diagnostics.len >= 1);
}

test "no trailing newline is left untouched" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scan(alloc, "hello", SkipSet{}, false);
    try std.testing.expectEqualStrings("hello", r.output);
    try std.testing.expect(!r.changed);
}

test "JB0002 BOM removal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scan(alloc, "\xEF\xBB\xBFhello\n", SkipSet{}, false);
    try std.testing.expectEqualStrings("hello\n", r.output);
    try std.testing.expect(r.changed);
}

test "clean file unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scan(alloc, "hello\n", SkipSet{}, false);
    try std.testing.expectEqualStrings("hello\n", r.output);
    try std.testing.expect(!r.changed);
}

test "JB0013 detects AWS key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scanSecrets(alloc, "aws_key = AKIAIOSFODNN7EXAMPLE\n", SkipSet{});
    try std.testing.expect(r.len >= 1);
    try std.testing.expectEqualStrings("AWS access key", r[0].message);
}

test "JB0013 detects GitHub PAT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scanSecrets(alloc, "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghij\n", SkipSet{});
    try std.testing.expect(r.len >= 1);
    try std.testing.expectEqualStrings("GitHub personal access token", r[0].message);
}

test "JB0013 detects private key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scanSecrets(alloc, "-----BEGIN RSA PRIVATE KEY-----\n", SkipSet{});
    try std.testing.expect(r.len >= 1);
    try std.testing.expectEqualStrings("Private key", r[0].message);
}

test "JB0013 detects sk- key with quote prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scanSecrets(alloc, "key = \"sk-abcdefghijklmnopqrstuvwxyz\"\n", SkipSet{});
    try std.testing.expect(r.len >= 1);
    try std.testing.expectEqualStrings("Possible API secret key (sk-...)", r[0].message);
}

test "JB0013 skips short tokens" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scanSecrets(alloc, "ghp_short\n", SkipSet{});
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "JB0013 skip set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    var s = SkipSet{};
    s.addRule(13);
    const r = scanSecrets(alloc, "AKIAIOSFODNN7EXAMPLE\n", s);
    try std.testing.expectEqual(@as(usize, 0), r.len);
}

test "dry run returns original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const input = "hello   \n";
    const r = scan(alloc, input, SkipSet{}, true);
    try std.testing.expectEqual(input.ptr, r.output.ptr);
    try std.testing.expect(!r.changed);
    try std.testing.expect(r.diagnostics.len >= 1);
}
