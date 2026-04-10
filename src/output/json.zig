const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;

pub fn render(writer: *std.Io.Writer, path: []const u8, diags: []const Diagnostic) !void {
    for (diags) |d| {
        try writer.print(
            \\{{"file":"{s}","line":{d},"col":{d},"rule":"{s}","message":"
        , .{
            path,
            d.line,
            d.col,
            d.displayName(),
        });
        try writeJsonString(writer, d.message);
        try writer.print(
            \\","severity":"{s}","fixable":{s}
        , .{
            if (d.rule.category() == .format) "format" else "lint",
            if (d.rule.fixable()) "true" else "false",
        });
        if (d.suggestion) |sug| {
            try writer.writeAll(",\"suggestion\":\"");
            try writeJsonString(writer, sug);
            try writer.writeByte('"');
        }
        try writer.writeAll("}\n");
    }
}

pub fn renderSummary(writer: *std.Io.Writer, total_errors: usize, total_files: usize, fixable: usize) !void {
    if (total_errors == 0) return;
    try writer.print(
        \\{{"summary":{{"errors":{d},"files":{d},"fixable":{d}}}}}
    , .{ total_errors, total_files, fixable });
    try writer.writeByte('\n');
}

fn writeJsonString(writer: *std.Io.Writer, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
}
