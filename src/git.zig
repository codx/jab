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

/// Return the subset of `paths` that git considers ignored, honouring nested
/// `.gitignore` files, `.git/info/exclude`, and the global `core.excludesFile`.
/// Delegates to `git check-ignore`, so it propagates an error when git is
/// unavailable or this isn't a repo — callers can then fall back to their own
/// matcher. Keys borrow the returned slices' memory, valid as long as the
/// allocator's arena lives.
pub fn ignoredSet(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) !std.StringHashMapUnmanaged(void) {
    var ignored: std.StringHashMapUnmanaged(void) = .{};

    // Chunk to stay well under ARG_MAX for large trees; check-ignore echoes
    // each ignored input path back, one per line. `-z` is rejected with
    // positional args (it only pairs with --stdin), and passing paths as args
    // avoids any stdin/stdout pipe deadlock. `core.quotePath=false` keeps
    // non-ASCII paths verbatim so they match our collected strings exactly.
    const chunk_size = 256;
    var i: usize = 0;
    while (i < paths.len) : (i += chunk_size) {
        const end = @min(i + chunk_size, paths.len);
        const chunk = paths[i..end];

        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(allocator, &.{ "git", "-c", "core.quotePath=false", "check-ignore" });
        try argv.appendSlice(allocator, chunk);

        const result = try std.process.Child.run(.{
            .allocator = allocator,
            .argv = argv.items,
            .max_output_bytes = 4 * 1024 * 1024,
        });

        switch (result.term) {
            // 0 = at least one path ignored, 1 = none ignored; both are fine.
            // Anything else (notably 128 = not a git repo) is a real failure.
            .Exited => |code| if (code != 0 and code != 1) return error.GitCommandFailed,
            else => return error.GitCommandFailed,
        }

        var it = std.mem.splitScalar(u8, result.stdout, '\n');
        while (it.next()) |line| {
            const p = std.mem.trim(u8, line, " \r");
            if (p.len == 0) continue;
            try ignored.put(allocator, p, {});
        }
    }

    return ignored;
}

test "getStagedFiles signature compiles" {
    _ = getStagedFiles;
    _ = ignoredSet;
}
