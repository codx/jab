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
    ".md",   ".toml",
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
    io: std.Io,
    paths: []const []const u8,
    opts: Options,
) ![]FileEntry {
    var files: std.ArrayList(FileEntry) = .empty;

    if (paths.len > 0) {
        for (paths) |p| {
            const stat = std.Io.Dir.cwd().statFile(io, p, .{}) catch continue;
            if (stat.kind == .directory) {
                try walkDir(allocator, io, p, &files, opts);
            } else {
                if (stat.size <= max_file_size) {
                    try files.append(allocator, .{ .path = p, .rel_path = p });
                }
            }
        }
    } else {
        try walkDir(allocator, io, ".", &files, opts);
    }

    return files.items;
}

fn walkDir(allocator: std.mem.Allocator, io: std.Io, dir_path: []const u8, files: *std.ArrayList(FileEntry), opts: Options) !void {
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(io);
    var w = dir.walk(allocator) catch return;
    defer w.deinit();

    while (w.next(io) catch null) |entry| {
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
            const trimmed_dir = std.mem.trimEnd(u8, dir_path, "/\\");
            const joined = std.fmt.allocPrint(allocator, "{s}/{s}", .{ trimmed_dir, path_str }) catch continue;
            break :blk joined;
        };

        files.append(allocator, .{
            .path = full_path,
            .rel_path = full_path,
        }) catch {};
    }
}

pub fn isSupportedFile(path: []const u8) bool {
    for (supported_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return true;
    }
    return false;
}

/// Number of leading bytes inspected by `looksBinary`. Matches git's own
/// binary heuristic (`buffer_is_binary` checks the first 8000 bytes).
const binary_sniff_len = 8000;

/// True if `content` contains a NUL byte within its first 8000 bytes, the same
/// heuristic git uses to decide a blob is binary.
pub fn looksBinary(content: []const u8) bool {
    const head = content[0..@min(content.len, binary_sniff_len)];
    return std.mem.indexOfScalar(u8, head, 0) != null;
}

/// True if a file that did not come through the directory walker (e.g. a
/// git-staged path) should be skipped as binary. The walker only yields
/// supported extensions, so binaries never reach the linter that way; staged
/// mode sees every staged path and must filter them itself. Files with a
/// supported extension are never skipped, so a stray NUL in e.g. a `.sh` is
/// still reported by the null-byte rule, consistent with the walker.
pub fn shouldSkipBinary(path: []const u8, content: []const u8) bool {
    if (isSupportedFile(path)) return false;
    return looksBinary(content);
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

test "looksBinary detects NUL in leading bytes only" {
    try std.testing.expect(!looksBinary(""));
    try std.testing.expect(!looksBinary("echo hi\n"));
    try std.testing.expect(looksBinary("\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR"));
    try std.testing.expect(looksBinary("abc\x00"));

    // A NUL past the sniff window is not considered (matches git).
    const late = @as([binary_sniff_len]u8, @splat('a')) ++ [_]u8{0};
    try std.testing.expect(!looksBinary(&late));
    const edge = @as([binary_sniff_len - 1]u8, @splat('a')) ++ [_]u8{0};
    try std.testing.expect(looksBinary(&edge));
}

test "shouldSkipBinary skips unsupported binaries, keeps supported files" {
    try std.testing.expect(shouldSkipBinary("img.png", "\x89PNG\r\n\x1a\n\x00\x00"));
    try std.testing.expect(shouldSkipBinary("Makefile", "a\x00b"));
    try std.testing.expect(!shouldSkipBinary("Makefile", "all:\n\ttrue\n"));
    // Supported files keep being linted so the null-byte rule still fires.
    try std.testing.expect(!shouldSkipBinary("deploy.sh", "echo hi\x00there\n"));
    try std.testing.expect(!shouldSkipBinary("x.py", "\x00"));
}

test "pathHasSkipComponent empty skips" {
    try std.testing.expect(!pathHasSkipComponent("node_modules/x", &.{}));
}
