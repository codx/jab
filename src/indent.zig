const std = @import("std");

pub const IndentStyle = enum {
    spaces_2,
    spaces_4,
    tabs,
    unknown,
};

pub fn detect(source: []const u8) IndentStyle {
    var tab_count: u32 = 0;
    var space_count: u32 = 0;
    var two_space: u32 = 0;
    var four_space: u32 = 0;
    var lines_checked: u32 = 0;

    var i: usize = 0;
    while (i < source.len and lines_checked < 50) {
        if (i == 0 or (i > 0 and source[i - 1] == '\n')) {
            if (i < source.len and source[i] == '\t') {
                tab_count += 1;
                lines_checked += 1;
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            } else if (i < source.len and source[i] == ' ') {
                var spaces: u32 = 0;
                const start = i;
                while (i < source.len and source[i] == ' ') : (i += 1) {
                    spaces += 1;
                }
                _ = start;
                if (spaces >= 2 and i < source.len and source[i] != '\n') {
                    space_count += 1;
                    if (spaces % 4 == 0) four_space += 1;
                    if (spaces % 2 == 0) two_space += 1;
                    lines_checked += 1;
                }
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            } else {
                while (i < source.len and source[i] != '\n') : (i += 1) {}
            }
        }
        if (i < source.len) i += 1;
    }

    if (tab_count == 0 and space_count == 0) return .unknown;
    if (tab_count > space_count) return .tabs;

    if (space_count > 0) {
        if (four_space > space_count / 2) return .spaces_4;
        return .spaces_2;
    }

    return .unknown;
}

pub fn indentStr(style: IndentStyle) []const u8 {
    return switch (style) {
        .spaces_2 => "  ",
        .spaces_4 => "    ",
        .tabs => "\t",
        .unknown => "  ",
    };
}

test "detect tabs" {
    const source = "\tfoo\n\tbar\n\tbaz\n";
    try std.testing.expectEqual(IndentStyle.tabs, detect(source));
}

test "detect 2 spaces" {
    const source = "  foo\n  bar\n    baz\n";
    try std.testing.expectEqual(IndentStyle.spaces_2, detect(source));
}

test "detect 4 spaces" {
    const source = "    foo\n    bar\n        baz\n    quux\n";
    try std.testing.expectEqual(IndentStyle.spaces_4, detect(source));
}

test "detect empty" {
    try std.testing.expectEqual(IndentStyle.unknown, detect("foo\nbar\n"));
}
