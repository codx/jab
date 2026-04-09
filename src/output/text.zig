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
    for (diags) |d| {
        // path:line:col: error[BKxxxx] Message
        try writer.print("{s}{s}{s}:{d}:{d}: {s}error[{s}]{s} {s}\n", .{
            color.bold(),
            path,
            color.reset(),
            d.line,
            d.col,
            color.red(),
            d.rule.name(),
            color.reset(),
            d.message,
        });

        const line_content = getLine(source, d.line);
        if (line_content.len > 0) {
            try writer.print("{s}   \xe2\x94\x82{s}\n", .{ color.dim(), color.reset() });
            try writer.print("{s}{d: >3} \xe2\x94\x82{s} {s}\n", .{ color.dim(), d.line, color.reset(), line_content });

            // Underline
            try writer.print("{s}   \xe2\x94\x82{s} ", .{ color.dim(), color.reset() });
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
            try writer.print("{s}   \xe2\x94\x82{s}\n", .{ color.dim(), color.reset() });
        }
    }
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
