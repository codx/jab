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
            if (!skip.shouldSkip(.JB0009)) {
                diags.add(allocator, .{ .rule = .JB0009, .line = line, .col = col, .message = "Null byte", .span_len = 1 }) catch {};
            }
            result.append(allocator, b) catch {};
            i += 1;
            col += 1;
            continue;
        }

        // JB0002: UTF-8 BOM
        if (i == 0 and source.len >= 3 and source[0] == 0xEF and source[1] == 0xBB and source[2] == 0xBF) {
            if (!skip.shouldSkip(.JB0002)) {
                diags.add(allocator, .{ .rule = .JB0002, .line = 1, .col = 1, .message = "UTF-8 BOM detected", .span_len = 3 }) catch {};
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
            if (!skip.shouldSkip(.JB0001)) {
                const line_start = findLineStart(source, i);
                const trimmed_end = trimTrailingWhitespace(source, line_start, i);
                if (trimmed_end < i) {
                    const ws_col: u32 = @intCast(trimmed_end - line_start + 1);
                    const ws_len: u32 = @intCast(i - trimmed_end);
                    diags.add(allocator, .{
                        .rule = .JB0001,
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
                if (!skip.shouldSkip(.JB0011)) {
                    diags.add(allocator, .{ .rule = .JB0011, .line = line, .col = col, .message = "Invalid UTF-8 byte sequence", .span_len = 1 }) catch {};
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
                    if (!skip.shouldSkip(.JB0003)) {
                        diags.add(allocator, .{ .rule = .JB0003, .line = line, .col = col, .message = "Zero-width character", .span_len = @intCast(seq_len) }) catch {};
                    }
                    if (!dry_run) {
                        i += seq_len;
                        continue;
                    }
                }

                // JB0004: Bidi overrides
                if (isBidiOverride(cp)) {
                    if (!skip.shouldSkip(.JB0004)) {
                        diags.add(allocator, .{ .rule = .JB0004, .line = line, .col = col, .message = "Bidi override character (CVE-2021-42574)", .span_len = @intCast(seq_len) }) catch {};
                    }
                    if (!dry_run) {
                        i += seq_len;
                        continue;
                    }
                }

                // JB0005: Non-breaking space
                if (cp == 0x00A0) {
                    if (!skip.shouldSkip(.JB0005)) {
                        diags.add(allocator, .{ .rule = .JB0005, .line = line, .col = col, .message = "Non-breaking space", .span_len = @intCast(seq_len), .suggestion = "Replace with regular space" }) catch {};
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
                    if (!skip.shouldSkip(.JB0006)) {
                        diags.add(allocator, .{ .rule = .JB0006, .line = line, .col = col, .message = "Homoglyph character (Cyrillic mimicking Latin)", .span_len = @intCast(seq_len) }) catch {};
                    }
                }

                // JB0010: Smart quotes
                if (isSmartQuote(cp)) {
                    if (!skip.shouldSkip(.JB0010)) {
                        const replacement: []const u8 = if (cp == 0x201C or cp == 0x201D) "\"" else "'";
                        diags.add(allocator, .{ .rule = .JB0010, .line = line, .col = col, .message = "Smart quote", .span_len = @intCast(seq_len), .suggestion = replacement }) catch {};
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
                if (!skip.shouldSkip(.JB0011)) {
                    diags.add(allocator, .{ .rule = .JB0011, .line = line, .col = col, .message = "Invalid UTF-8 byte sequence", .span_len = @intCast(seq_len) }) catch {};
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
    if (!skip.shouldSkip(.JB0001) and result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
        const last_nl = if (std.mem.lastIndexOfScalar(u8, result.items, '\n')) |p| p + 1 else 0;
        const trimmed_end = trimTrailingWhitespace(result.items, last_nl, result.items.len);
        if (trimmed_end < result.items.len) {
            const ws_len: u32 = @intCast(result.items.len - trimmed_end);
            diags.add(allocator, .{
                .rule = .JB0001,
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
    if (has_crlf and has_lf and !skip.shouldSkip(.JB0008)) {
        diags.add(allocator, .{ .rule = .JB0008, .line = 1, .col = 1, .message = "Mixed line endings (CRLF + LF)" }) catch {};
    }

    // JB0007: Missing trailing newline
    if (result.items.len > 0 and result.items[result.items.len - 1] != '\n') {
        if (!skip.shouldSkip(.JB0007)) {
            diags.add(allocator, .{ .rule = .JB0007, .line = line, .col = col, .message = "Missing trailing newline" }) catch {};
        }
        if (!dry_run) {
            result.append(allocator, '\n') catch {};
        }
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

test "JB0001 trailing whitespace" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scan(alloc, "hello   \nworld\n", SkipSet{}, false);
    try std.testing.expectEqualStrings("hello\nworld\n", r.output);
    try std.testing.expect(r.changed);
    try std.testing.expect(r.diagnostics.len >= 1);
}

test "JB0007 missing trailing newline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const r = scan(alloc, "hello", SkipSet{}, false);
    try std.testing.expectEqualStrings("hello\n", r.output);
    try std.testing.expect(r.changed);
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
