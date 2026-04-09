const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const universal = @import("universal.zig");
const engine_mod = @import("engine.zig");
const walker = @import("walker.zig");
const git = @import("git.zig");
const text_output = @import("output/text.zig");
const github_output = @import("output/github.zig");

const SkipSet = diagnostic.SkipSet;
const Diagnostic = diagnostic.Diagnostic;

const version = "0.1.0";

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const args = try std.process.argsAlloc(allocator);

    var fix_mode = false;
    var staged = false;
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
        } else if (std.mem.eql(u8, arg, "-f")) {
            fix_mode = true;
        } else if (std.mem.eql(u8, arg, "--staged")) {
            staged = true;
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

    // Detect output mode
    const is_github = isGitHubActions();
    const color = text_output.Color.detect();

    var buf: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&buf);
    const stdout = &stdout_writer.interface;

    var total_diags: usize = 0;
    var total_fixable: usize = 0;
    var files_with_errors: usize = 0;

    for (file_paths) |path| {
        const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch continue;

        // Phase 1: Universal byte scan
        const universal_result = universal.scan(allocator, source, skip, !fix_mode);

        // Phase 2: Language engine
        const engine_result = engine_mod.processFile(
            allocator,
            universal_result.output,
            path,
            skip,
            !fix_mode,
        );

        // Collect + sort diagnostics by line:col
        var all_diags: std.ArrayList(Diagnostic) = .empty;
        for (universal_result.diagnostics) |d| {
            try all_diags.append(allocator, d);
        }
        if (engine_result) |er| {
            for (er.diagnostics) |d| {
                try all_diags.append(allocator, d);
            }
        }

        // Sort by line, then col
        std.mem.sortUnstable(Diagnostic, all_diags.items, {}, struct {
            fn lessThan(_: void, a: Diagnostic, b_diag: Diagnostic) bool {
                if (a.line != b_diag.line) return a.line < b_diag.line;
                return a.col < b_diag.col;
            }
        }.lessThan);

        if (all_diags.items.len > 0) {
            files_with_errors += 1;
            total_diags += all_diags.items.len;
            for (all_diags.items) |d| {
                if (d.rule.fixable()) total_fixable += 1;
            }

            if (is_github) {
                try github_output.render(stdout, path, all_diags.items);
            } else {
                try text_output.render(stdout, path, source, all_diags.items, color);
            }
        }

        // Write fixed output
        if (fix_mode) {
            const final_output = if (engine_result) |er|
                (if (er.changed) er.output else universal_result.output)
            else
                universal_result.output;

            if (universal_result.changed or (engine_result != null and engine_result.?.changed)) {
                const file = std.fs.cwd().createFile(path, .{}) catch continue;
                defer file.close();
                file.writeAll(final_output) catch {};
            }
        }
    }

    if (!is_github and total_diags > 0) {
        try text_output.renderSummary(stdout, total_diags, files_with_errors, total_fixable, color);
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

fn isGitHubActions() bool {
    const env = std.process.getEnvVarOwned(std.heap.page_allocator, "GITHUB_ACTIONS") catch return false;
    defer std.heap.page_allocator.free(env);
    return std.mem.eql(u8, env, "true");
}

comptime {
    _ = @import("diagnostic.zig");
    _ = @import("indent.zig");
    _ = @import("universal.zig");
    _ = @import("engine.zig");
    _ = @import("engine/json.zig");
    _ = @import("engine/bash.zig");
    _ = @import("engine/yaml.zig");
    _ = @import("engine/python.zig");
    _ = @import("engine/hcl.zig");
    _ = @import("treesitter.zig");
    _ = @import("walker.zig");
    _ = @import("git.zig");
}
