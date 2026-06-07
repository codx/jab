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
    ".tf",   ".tfvars",
    ".hcl",  ".tofu",
    ".md",
    ".toml",
};

pub const default_skip_dirs = [_][]const u8{
    "node_modules",
    "vendor",
    "target",
    "dist",
    "__pycache__",
};

pub const Options = struct {
    /// Directory names to skip during recursive walks. Match is per path
    /// component (e.g. "vendor" skips "vendor/x" and "a/vendor/x" but not
    /// "vendorx/y"). Pass an empty slice to disable.
    skip_dirs: []const []const u8 = &default_skip_dirs,
};

const max_file_size = 1024 * 1024; // 1MB

pub fn collectFiles(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    opts: Options,
) ![]FileEntry {
    var files: std.ArrayList(FileEntry) = .empty;

    if (paths.len > 0) {
        for (paths) |p| {
            const stat = std.fs.cwd().statFile(p) catch continue;
            if (stat.kind == .directory) {
                try walkDir(allocator, p, &files, opts);
            } else {
                if (stat.size <= max_file_size) {
                    try files.append(allocator, .{ .path = p, .rel_path = p });
                }
            }
        }
    } else {
        try walkDir(allocator, ".", &files, opts);
    }

    return files.items;
}

fn walkDir(allocator: std.mem.Allocator, dir_path: []const u8, files: *std.ArrayList(FileEntry), opts: Options) !void {
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

        if (pathHasSkipComponent(path_str, opts.skip_dirs)) continue;

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

/// True if any `/`-delimited component of `path` exactly matches an entry in `skips`.
/// "vendor" matches "vendor/x" and "a/vendor/x" but not "vendorx/x".
fn pathHasSkipComponent(path: []const u8, skips: []const []const u8) bool {
    if (skips.len == 0) return false;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= path.len) : (i += 1) {
        if (i == path.len or path[i] == '/' or path[i] == '\\') {
            const component = path[start..i];
            if (component.len > 0) {
                for (skips) |s| {
                    if (std.mem.eql(u8, component, s)) return true;
                }
            }
            start = i + 1;
        }
    }
    return false;
}

test "isSupportedFile" {
    try std.testing.expect(isSupportedFile("foo.json"));
    try std.testing.expect(isSupportedFile("bar.py"));
    try std.testing.expect(isSupportedFile("deploy.sh"));
    try std.testing.expect(isSupportedFile("readme.md"));
    try std.testing.expect(isSupportedFile("config.toml"));
    try std.testing.expect(!isSupportedFile("Makefile"));
}

test "pathHasSkipComponent matches whole components only" {
    const skips = &[_][]const u8{ "node_modules", "vendor" };
    try std.testing.expect(pathHasSkipComponent("node_modules/pkg/index.json", skips));
    try std.testing.expect(pathHasSkipComponent("a/b/vendor/x.zig", skips));
    try std.testing.expect(pathHasSkipComponent("vendor", skips));
    try std.testing.expect(!pathHasSkipComponent("vendorx/x.zig", skips));
    try std.testing.expect(!pathHasSkipComponent("my_node_modules/x.zig", skips));
    try std.testing.expect(!pathHasSkipComponent("src/main.zig", skips));
}

test "pathHasSkipComponent empty skips" {
    try std.testing.expect(!pathHasSkipComponent("node_modules/x", &.{}));
}
