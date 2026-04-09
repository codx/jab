const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;

pub fn render(writer: *std.Io.Writer, path: []const u8, diags: []const Diagnostic) !void {
    for (diags) |d| {
        try writer.print("::error file={s},line={d},col={d},title={s}::{s}\n", .{
            path,
            d.line,
            d.col,
            d.rule.name(),
            d.message,
        });
    }
}
