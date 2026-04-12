const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const universal = @import("universal.zig");
const engine_mod = @import("engine.zig");
const walker = @import("walker.zig");
const git = @import("git.zig");
const external = @import("external.zig");
const text_output = @import("output/text.zig");
const github_output = @import("output/github.zig");
const json_output = @import("output/json.zig");

const SkipSet = diagnostic.SkipSet;
const Diagnostic = diagnostic.Diagnostic;

const version = "0.1.0";

const Format = enum {
    text,
    json,
    github,
};

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    var fix_mode = false;
    var staged = false;
    var ext = false;
    var format: ?Format = null;
    var skip = SkipSet{};
    var explicit_files: std.ArrayList([]const u8) = .empty;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--version")) {
            var buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&buf);
            const stdout = &stdout_writer.interface;
            try stdout.print("jab {s}\n", .{version});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            var buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&buf);
            const stdout = &stdout_writer.interface;
            try stdout.print(
                \\jab {s} — lint, fix, and format Bash/JSON/YAML/Python/HCL
                \\
                \\Usage: jab [options] [files/dirs...]
                \\
                \\Options:
                \\  -f, --fix        Fix and format files in-place
                \\  --staged         Check only git-staged files (pre-commit mode)
                \\  --ext            Also run external tools (shellcheck, yamllint, ruff, ty, tofu, hadolint, actionlint, taplo, nixfmt)
                \\  --skip=<rules>   Skip rules or categories (comma-separated, e.g. JB1001,JB2)
                \\  --format=<fmt>   Output format: text (default), json, github
                \\  --health         Check which external tools are available on $PATH
                \\  --version        Print version
                \\  -h, --help       Show this help
                \\
                \\Exit codes:
                \\  0  Clean (no issues, or all fixed)
                \\  1  Diagnostics found (check mode) or unfixable issues remain (fix mode)
                \\  2  Tool error
                \\
            , .{version});
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--health")) {
            var buf: [4096]u8 = undefined;
            var stdout_writer = std.fs.File.stdout().writer(&buf);
            const stdout = &stdout_writer.interface;
            const color = text_output.Color.detect();
            try stdout.print("\n  {s}Tool          Language        Status{s}\n", .{ color.bold(), color.reset() });
            try stdout.print("  {s}\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80{s}\n", .{ color.dim(), color.reset() });
            const tools = [_]struct { name: []const u8, pad: []const u8, langs: []const u8, lpad: []const u8 }{
                .{ .name = "shellcheck", .pad = "    ", .langs = "Bash", .lpad = "            " },
                .{ .name = "yamllint", .pad = "      ", .langs = "YAML", .lpad = "            " },
                .{ .name = "ruff", .pad = "          ", .langs = "Python", .lpad = "          " },
                .{ .name = "ty", .pad = "            ", .langs = "Python", .lpad = "          " },
                .{ .name = "tofu", .pad = "          ", .langs = "HCL/Terraform", .lpad = "   " },
                .{ .name = "hadolint", .pad = "      ", .langs = "Dockerfile", .lpad = "      " },
                .{ .name = "actionlint", .pad = "    ", .langs = "GH Actions", .lpad = "      " },
                .{ .name = "taplo", .pad = "         ", .langs = "TOML", .lpad = "            " },
                .{ .name = "nixfmt", .pad = "        ", .langs = "Nix", .lpad = "             " },
            };
            var found: usize = 0;
            for (tools) |t| {
                const ok = external.findOnPath(t.name);
                if (ok) found += 1;
                try stdout.print("  {s}{s}{s}{s}{s}{s}{s}{s}\n", .{
                    t.name,
                    t.pad,
                    t.langs,
                    t.lpad,
                    color.bold(),
                    if (ok) color.green() else color.red(),
                    if (ok) "\xe2\x9c\x93" else "\xe2\x9c\x97",
                    color.reset(),
                });
            }
            try stdout.print("\n  {s}{d}/{d} available{s}. Use {s}--ext{s} to enable.\n\n", .{
                if (found == tools.len) color.green() else color.dim(),
                found,
                tools.len,
                color.reset(),
                color.bold(),
                color.reset(),
            });
            try stdout.flush();
            return;
        } else if (std.mem.eql(u8, arg, "--fix") or std.mem.eql(u8, arg, "-f")) {
            fix_mode = true;
        } else if (std.mem.eql(u8, arg, "--staged")) {
            staged = true;
        } else if (std.mem.eql(u8, arg, "--ext")) {
            ext = true;
        } else if (std.mem.startsWith(u8, arg, "--format=")) {
            const fmt_str = arg[9..];
            if (std.mem.eql(u8, fmt_str, "text")) {
                format = .text;
            } else if (std.mem.eql(u8, fmt_str, "json")) {
                format = .json;
            } else if (std.mem.eql(u8, fmt_str, "github")) {
                format = .github;
            } else {
                var buf: [4096]u8 = undefined;
                var stderr_writer = std.fs.File.stderr().writer(&buf);
                const stderr = &stderr_writer.interface;
                try stderr.print("jab: unknown format '{s}' (expected text, json, github)\n", .{fmt_str});
                try stderr.flush();
                std.process.exit(2);
            }
        } else if (std.mem.startsWith(u8, arg, "--skip=")) {
            skip = SkipSet.parse(arg[7..]);
        } else if (arg.len > 0 and arg[0] != '-') {
            try explicit_files.append(allocator, arg);
        } else {
            var buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&buf);
            const stderr = &stderr_writer.interface;
            try stderr.print("jab: unknown option '{s}'\n", .{arg});
            try stderr.flush();
            std.process.exit(2);
        }
    }

    // Resolve output format: explicit flag > env detection > text
    const output_format: Format = format orelse
        if (isGitHubActions()) .github else .text;

    // Resolve file list
    var file_paths: []const []const u8 = &.{};
    if (staged) {
        file_paths = git.getStagedFiles(allocator) catch {
            var buf: [4096]u8 = undefined;
            var stderr_writer = std.fs.File.stderr().writer(&buf);
            const stderr = &stderr_writer.interface;
            try stderr.print("jab: failed to get staged files (not a git repo?)\n", .{});
            try stderr.flush();
            std.process.exit(2);
            unreachable;
        };
    } else if (explicit_files.items.len > 0) {
        const entries = try walker.collectFiles(allocator, explicit_files.items);
        var paths: std.ArrayList([]const u8) = .empty;
        for (entries) |e| {
            try paths.append(allocator, e.path);
        }
        file_paths = paths.items;
    } else {
        const entries = try walker.collectFiles(allocator, &.{});
        var paths: std.ArrayList([]const u8) = .empty;
        for (entries) |e| {
            try paths.append(allocator, e.path);
        }
        file_paths = paths.items;
    }

    // Detect available external tools once (avoids repeated PATH lookups per file)
    const tools = if (ext) external.ToolSet.detect() else external.ToolSet{};

    const color = text_output.Color.detect();

    var buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;

    // --- Phase 1+2: per-file jab analysis ---
    const FileState = struct {
        path: []const u8,
        source: []const u8,
        universal_output: []const u8,
        universal_changed: bool,
        engine_output: ?[]const u8,
        engine_changed: bool,
        diags: std.ArrayList(Diagnostic),
    };

    var file_results: std.ArrayList(FileState) = .empty;

    // JB0012: Check for OS/editor junk files before walker filters them out
    if (!skip.shouldSkip(.junk_file)) {
        const raw_paths = if (staged)
            file_paths
        else
            explicit_files.items;
        for (raw_paths) |path| {
            if (isJunkFile(path)) {
                var diag_list: std.ArrayList(Diagnostic) = .empty;
                try diag_list.append(allocator, .{
                    .rule = .junk_file,
                    .line = 0,
                    .col = 0,
                    .message = if (containsJunkDir(path))
                        "cache/build artifact should not be committed"
                    else
                        "OS/editor junk file should not be committed",
                });
                try file_results.append(allocator, .{
                    .path = path,
                    .source = "",
                    .universal_output = "",
                    .universal_changed = false,
                    .engine_output = null,
                    .engine_changed = false,
                    .diags = diag_list,
                });
            }
        }
    }

    for (file_paths) |path| {
        const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch continue;

        var diag_list: std.ArrayList(Diagnostic) = .empty;

        // JB0014: Large file warning (>512KB)
        if (!skip.shouldSkip(.large_file) and source.len > 512 * 1024) {
            try diag_list.append(allocator, .{
                .rule = .large_file,
                .line = 0,
                .col = 0,
                .message = "File exceeds 512KB",
            });
        }

        const universal_result = universal.scan(allocator, source, skip, !fix_mode);
        const engine_result = engine_mod.processFile(
            allocator,
            universal_result.output,
            path,
            skip,
            !fix_mode,
        );

        for (universal_result.diagnostics) |d| {
            try diag_list.append(allocator, d);
        }
        // JB0013: Secret detection
        for (universal.scanSecrets(allocator, source, skip)) |d| {
            try diag_list.append(allocator, d);
        }
        if (engine_result) |er| {
            for (er.diagnostics) |d| {
                try diag_list.append(allocator, d);
            }
        }

        try file_results.append(allocator, .{
            .path = path,
            .source = source,
            .universal_output = universal_result.output,
            .universal_changed = universal_result.changed,
            .engine_output = if (engine_result) |er| (if (er.changed) er.output else null) else null,
            .engine_changed = if (engine_result) |er| er.changed else false,
            .diags = diag_list,
        });
    }

    // --- Phase 3: batched external tools (--ext only) ---
    if (ext) {
        try external.runBatchedExternalTools(allocator, file_results.items, tools);
    }

    // --- Phase 4: render + fix ---
    var total_diags: usize = 0;
    var total_fixable: usize = 0;
    var files_with_errors: usize = 0;

    for (file_results.items) |*fr| {
        // Sort by line, then col
        std.mem.sortUnstable(Diagnostic, fr.diags.items, {}, struct {
            fn lessThan(_: void, a: Diagnostic, b_diag: Diagnostic) bool {
                if (a.line != b_diag.line) return a.line < b_diag.line;
                return a.col < b_diag.col;
            }
        }.lessThan);

        if (fr.diags.items.len > 0) {
            files_with_errors += 1;
            total_diags += fr.diags.items.len;
            for (fr.diags.items) |d| {
                if (d.rule.fixable()) total_fixable += 1;
            }

            switch (output_format) {
                .text => try text_output.render(stdout, fr.path, fr.source, fr.diags.items, color),
                .json => try json_output.render(stdout, fr.path, fr.diags.items),
                .github => try github_output.render(stdout, fr.path, fr.diags.items),
            }
        }

        if (fix_mode) {
            const final_output = fr.engine_output orelse fr.universal_output;

            if (fr.universal_changed or fr.engine_changed) {
                const file = std.fs.cwd().createFile(fr.path, .{}) catch continue;
                defer file.close();
                file.writeAll(final_output) catch {};
            }

            if (ext) {
                external.runExternalFixes(allocator, fr.path, tools);
            }
        }
    }

    if (total_diags > 0) {
        switch (output_format) {
            .text => try text_output.renderSummary(stdout, total_diags, files_with_errors, total_fixable, color),
            .json => try json_output.renderSummary(stdout, total_diags, files_with_errors, total_fixable),
            .github => {},
        }
    }

    try stdout.flush();

    if (total_diags > 0) {
        if (fix_mode) {
            if (total_diags > total_fixable) {
                std.process.exit(1);
            }
            std.process.exit(0);
        }
        std.process.exit(1);
    }
}

fn isJunkFile(path: []const u8) bool {
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
    const junk_names = [_][]const u8{
        ".DS_Store",
        "Thumbs.db",
        "Desktop.ini",
        ".Spotlight-V100",
        ".Trashes",
        ".directory",
    };
    for (junk_names) |junk| {
        if (std.mem.eql(u8, basename, junk)) return true;
    }
    // ._* (macOS resource fork files) and *~ (editor backup files)
    if (basename.len >= 2 and basename[0] == '.' and basename[1] == '_') return true;
    if (basename.len > 0 and basename[basename.len - 1] == '~') return true;
    // .swp / .swo (vim swap files)
    if (std.mem.endsWith(u8, basename, ".swp") or std.mem.endsWith(u8, basename, ".swo")) return true;
    // Cache/build directories that shouldn't be committed
    if (containsJunkDir(path)) return true;
    return false;
}

fn containsJunkDir(path: []const u8) bool {
    const junk_dirs = [_][]const u8{
        "__pycache__/",
        ".mypy_cache/",
        ".pytest_cache/",
        ".ruff_cache/",
        "node_modules/",
        ".terraform/",
        ".terragrunt-cache/",
        "zig-cache/",
        ".zig-cache/",
        "zig-out/",
        ".gradle/",
        ".cargo/registry/",
        ".venv/",
        ".tox/",
        ".nox/",
        ".eggs/",
    };
    for (junk_dirs) |dir| {
        if (std.mem.indexOf(u8, path, dir) != null) return true;
    }
    // *.egg-info/ — suffix match for Python egg directories
    if (std.mem.indexOf(u8, path, ".egg-info/") != null) return true;
    return false;
}

fn isGitHubActions() bool {
    const env = std.process.getEnvVarOwned(std.heap.page_allocator, "GITHUB_ACTIONS") catch return false;
    defer std.heap.page_allocator.free(env);
    return std.mem.eql(u8, env, "true");
}

test "isJunkFile detects DS_Store" {
    try std.testing.expect(isJunkFile(".DS_Store"));
    try std.testing.expect(isJunkFile("subdir/.DS_Store"));
}

test "isJunkFile detects editor backups" {
    try std.testing.expect(isJunkFile("file.txt~"));
    try std.testing.expect(isJunkFile(".file.swp"));
    try std.testing.expect(isJunkFile(".file.swo"));
}

test "isJunkFile detects resource fork files" {
    try std.testing.expect(isJunkFile("._something"));
}

test "isJunkFile rejects normal files" {
    try std.testing.expect(!isJunkFile("main.zig"));
    try std.testing.expect(!isJunkFile("src/lib.py"));
}

test "containsJunkDir detects cache dirs" {
    try std.testing.expect(containsJunkDir("src/__pycache__/foo.pyc"));
    try std.testing.expect(containsJunkDir("node_modules/pkg/index.js"));
    try std.testing.expect(containsJunkDir(".terraform/providers/foo"));
    try std.testing.expect(containsJunkDir("proj/.zig-cache/o/test"));
    try std.testing.expect(containsJunkDir("lib/foo.egg-info/PKG-INFO"));
}

test "containsJunkDir rejects normal paths" {
    try std.testing.expect(!containsJunkDir("src/main.zig"));
    try std.testing.expect(!containsJunkDir("terraform/main.tf"));
}

comptime {
    _ = @import("diagnostic.zig");
    _ = @import("indent.zig");
    _ = @import("universal.zig");
    _ = @import("engine.zig");
    _ = @import("external.zig");
    _ = @import("engine/json.zig");
    _ = @import("engine/bash.zig");
    _ = @import("engine/yaml.zig");
    _ = @import("engine/python.zig");
    _ = @import("engine/hcl.zig");
    _ = @import("treesitter.zig");
    _ = @import("walker.zig");
    _ = @import("git.zig");
    _ = @import("output/json.zig");
    _ = @import("output/text.zig");
    _ = @import("output/github.zig");
    _ = @import("engine/markdown.zig");
}
