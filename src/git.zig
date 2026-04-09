const std = @import("std");

pub fn getStagedFiles(allocator: std.mem.Allocator) ![][]const u8 {
    const result = try std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "git", "diff", "--staged", "--name-only", "--diff-filter=ACMR" },
        .max_output_bytes = 50 * 1024,
    });

    if (result.term != .Exited or result.term.Exited != 0) {
        return error.GitCommandFailed;
    }

    var files: std.ArrayList([]const u8) = .empty;
    var iter = std.mem.splitScalar(u8, result.stdout, '\n');
    while (iter.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");
        if (trimmed.len == 0) continue;
        try files.append(allocator, try allocator.dupe(u8, trimmed));
    }

    return files.items;
}

test "getStagedFiles signature compiles" {
    _ = getStagedFiles;
}
