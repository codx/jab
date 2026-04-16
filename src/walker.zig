const std = @import("std");

pub const FileEntry = struct {
    path: []const u8,
    rel_path: []const u8,
};

const supported_extensions = [_][]const u8{
    ".json", ".jsonc",
    ".yaml", ".yml",
    ".sh",   ".bash",
    ".py",   ".pyi",
    ".tf",   ".tfvars", ".hcl", ".tofu",
    ".md",
};

const max_file_size = 1024 * 1024; // 1MB

pub fn collectFiles(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
) ![]FileEntry {
    var files: std.ArrayList(FileEntry) = .empty;

    if (paths.len > 0) {
        for (paths) |p| {
            const stat = std.fs.cwd().statFile(p) catch continue;
            if (stat.kind == .directory) {
                try walkDir(allocator, p, &files);
            } else {
                if (stat.size <= max_file_size) {
                    try files.append(allocator, .{ .path = p, .rel_path = p });
                }
            }
        }
    } else {
        try walkDir(allocator, ".", &files);
    }

    return files.items;
}

fn walkDir(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList(FileEntry)) !void {
    const dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    var w = dir.walk(allocator) catch return;
    defer w.deinit();

    while (w.next() catch null) |entry| {
        if (entry.kind == .sym_link) continue;
        if (entry.kind != .file) continue;

        const bname = entry.basename;
        if (bname.len > 0 and bname[0] == '.') continue;

        const path_str = entry.path;
        if (std.mem.indexOf(u8, path_str, ".git/") != null) continue;
        if (std.mem.indexOf(u8, path_str, ".git\\") != null) continue;

        if (!isSupportedFile(bname)) continue;

        const full_path = if (std.mem.eql(u8, dir_path, "."))
            allocator.dupe(u8, path_str) catch continue
        else blk: {
            const trimmed_dir = std.mem.trimRight(u8, dir_path, "/\\");
            const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_dir, path_str }) catch continue;
            break :blk joined;
        };

        files.append(allocator, .{
            .path = full_path,
            .rel_path = full_path,
        }) catch {};
    }
}

fn isSupportedFile(path: []const u8) bool {
    for (supported_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

test "isSupportedFile" {
    try std.testing.expect(isSupportedFile("foo.json"));
    try std.testing.expect(isSupportedFile("bar.py"));
    try std.testing.expect(isSupportedFile("deploy.sh"));
    try std.testing.expect(isSupportedFile("readme.md"));
    try std.testing.expect(!isSupportedFile("Makefile"));
}
