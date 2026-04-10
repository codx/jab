const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;

pub const Color = struct {
    enabled: bool,

    pub fn detect() Color {
        if (getEnvBool("NO_COLOR") or getEnvBool("CI")) return .{ .enabled = false };
        const stdout_handle = std.fs.File.stdout().handle;
        return .{ .enabled = std.posix.isatty(stdout_handle) };
    }

    pub fn bold(self: Color) []const u8 {
        return if (self.enabled) "\x1b[1m" else "";
    }

    pub fn red(self: Color) []const u8 {
        return if (self.enabled) "\x1b[31m" else "";
    }

    pub fn cyan(self: Color) []const u8 {
        return if (self.enabled) "\x1b[36m" else "";
    }

    pub fn green(self: Color) []const u8 {
        return if (self.enabled) "\x1b[32m" else "";
    }

    pub fn dim(self: Color) []const u8 {
        return if (self.enabled) "\x1b[2m" else "";
    }

    pub fn reset(self: Color) []const u8 {
        return if (self.enabled) "\x1b[0m" else "";
    }

    fn getEnvBool(name: []const u8) bool {
        const val = std.process.getEnvVarOwned(std.heap.page_allocator, name) catch return false;
        defer std.heap.page_allocator.free(val);
        return val.len > 0;
    }
};

pub fn render(writer: *std.Io.Writer, path: []const u8, source: []const u8, diags: []const Diagnostic, color: Color) !void {
    // Compute gutter width from max line number (minimum 3 for aesthetics)
    var max_line: u32 = 0;
    for (diags) |d| {
        if (d.line > max_line) max_line = d.line;
    }
    const gutter = digitCount(max_line);

    for (diags) |d| {
        // path:line:col: error[BKxxxx] Message
        try writer.print("{s}{s}{s}:{d}:{d}: {s}error[{s}]{s} {s}\n", .{
            color.bold(),
            path,
            color.reset(),
            d.line,
            d.col,
            color.red(),
            d.displayName(),
            color.reset(),
            d.message,
        });

        const line_content = getLine(source, d.line);
        if (line_content.len > 0) {
            try writeGutter(writer, gutter, color);
            try writer.writeByte('\n');
            try writeLineNum(writer, d.line, gutter, color);
            try writer.print(" {s}\n", .{line_content});

            // Underline
            try writeGutter(writer, gutter, color);
            try writer.writeByte(' ');
            var col: u32 = 1;
            while (col < d.col) : (col += 1) {
                try writer.writeByte(' ');
            }
            try writer.writeAll(color.red());
            var span: u32 = 0;
            while (span < @max(d.span_len, 1)) : (span += 1) {
                try writer.writeByte('^');
            }
            try writer.writeAll(color.reset());
            if (d.suggestion) |sug| {
                try writer.print(" {s}", .{sug});
            }
            try writer.writeByte('\n');
            try writeGutter(writer, gutter, color);
            try writer.writeByte('\n');
        }
    }
}

/// Write gutter without trailing newline: "    │"
fn writeGutter(writer: *std.Io.Writer, width: u16, color: Color) !void {
    try writer.writeAll(color.dim());
    var i: u16 = 0;
    while (i < width) : (i += 1) {
        try writer.writeByte(' ');
    }
    try writer.writeAll(" \xe2\x94\x82");
    try writer.writeAll(color.reset());
}

/// Write a line number + gutter: " 42 │" right-aligned to width.
fn writeLineNum(writer: *std.Io.Writer, line: u32, width: u16, color: Color) !void {
    const num_digits = rawDigitCount(line);
    try writer.writeAll(color.dim());
    var pad: u16 = num_digits;
    while (pad < width) : (pad += 1) {
        try writer.writeByte(' ');
    }
    try writer.print("{d} \xe2\x94\x82", .{line});
    try writer.writeAll(color.reset());
}

fn rawDigitCount(n: u32) u16 {
    if (n == 0) return 1;
    var count: u16 = 0;
    var v = n;
    while (v > 0) : (v /= 10) {
        count += 1;
    }
    return count;
}

fn digitCount(n: u32) u16 {
    return @max(rawDigitCount(n), 3); // minimum 3 for aesthetics
}

pub fn renderSummary(writer: *std.Io.Writer, total_errors: usize, total_files: usize, fixable: usize, color: Color) !void {
    if (total_errors == 0) return;
    try writer.print("\n{s}{d} error{s} in {d} file{s}{s}", .{
        color.bold(),
        total_errors,
        if (total_errors != 1) "s" else "",
        total_files,
        if (total_files != 1) "s" else "",
        color.reset(),
    });
    if (fixable > 0) {
        try writer.print(" {s}\xe2\x80\x94 {d} fixable{s}", .{ color.cyan(), fixable, color.reset() });
    }
    try writer.writeByte('\n');
}

fn getLine(source: []const u8, target_line: u32) []const u8 {
    var line: u32 = 1;
    var start: usize = 0;
    for (source, 0..) |c, i| {
        if (line == target_line) {
            if (c == '\n') return source[start..i];
        }
        if (c == '\n') {
            line += 1;
            start = i + 1;
        }
    }
    if (line == target_line and start < source.len) {
        return source[start..];
    }
    return "";
}
