const std = @import("std");
const diagnostic = @import("diagnostic.zig");
const Diagnostic = diagnostic.Diagnostic;
const RuleId = diagnostic.RuleId;

/// Run external tools on a file and return additional diagnostics.
/// Uses a pre-detected ToolSet to avoid repeated PATH lookups.
pub fn runExternalTools(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
    tools: ToolSet,
) !void {
    if (tools.shellcheck and isShellFile(path)) {
        try runShellcheck(allocator, path, diags, existing_lines);
    }
    if (tools.yamllint and isYamlFile(path)) {
        try runYamllint(allocator, path, diags, existing_lines);
    }
    if (isPythonFile(path)) {
        if (tools.ruff) try runRuff(allocator, path, diags, existing_lines);
        if (tools.ty) try runTy(allocator, path, diags, existing_lines);
    }
    if (tools.tofu and isHclFile(path)) {
        try runTofuFmt(allocator, path, diags);
    }
    if (tools.hadolint and isDockerfile(path)) {
        try runHadolint(allocator, path, diags, existing_lines);
    }
    if (tools.actionlint and isGHActionsFile(path)) {
        try runActionlint(allocator, path, diags, existing_lines);
    }
    if (tools.taplo and isTomlFile(path)) {
        try runTaploFmt(allocator, path, diags);
    }
    if (tools.nixfmt and isNixFile(path)) {
        try runNixfmt(allocator, path, diags);
    }
}

fn isShellFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".sh") or std.mem.endsWith(u8, path, ".bash");
}

fn isYamlFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".yaml") or std.mem.endsWith(u8, path, ".yml");
}

fn isPythonFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".py") or std.mem.endsWith(u8, path, ".pyi");
}

fn isHclFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".tf") or
        std.mem.endsWith(u8, path, ".tfvars") or
        std.mem.endsWith(u8, path, ".hcl") or
        std.mem.endsWith(u8, path, ".tofu");
}

fn isDockerfile(path: []const u8) bool {
    // Match Dockerfile, Dockerfile.prod, etc.
    const basename = if (std.mem.lastIndexOfScalar(u8, path, '/')) |idx| path[idx + 1 ..] else path;
    return std.mem.startsWith(u8, basename, "Dockerfile") or
        std.mem.endsWith(u8, basename, ".dockerfile") or
        std.mem.eql(u8, basename, "Containerfile");
}

fn isGHActionsFile(path: []const u8) bool {
    return (std.mem.indexOf(u8, path, ".github/workflows/") != null) and
        (std.mem.endsWith(u8, path, ".yml") or std.mem.endsWith(u8, path, ".yaml"));
}

fn isTomlFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".toml");
}

fn isNixFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".nix");
}

pub fn findOnPath(tool: []const u8) bool {
    const path_var = std.process.getEnvVarOwned(std.heap.page_allocator, "PATH") catch return false;
    defer std.heap.page_allocator.free(path_var);
    return findOnPathIn(path_var, tool);
}

fn findOnPathIn(path_var: []const u8, tool: []const u8) bool {
    var it = std.mem.splitScalar(u8, path_var, ':');
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, tool }) catch continue;
        _ = std.fs.cwd().statFile(full) catch continue;
        return true;
    }
    return false;
}

pub const ToolSet = struct {
    shellcheck: bool = false,
    yamllint: bool = false,
    ruff: bool = false,
    ty: bool = false,
    tofu: bool = false,
    hadolint: bool = false,
    actionlint: bool = false,
    taplo: bool = false,
    nixfmt: bool = false,

    pub fn detect() ToolSet {
        const path_var = std.process.getEnvVarOwned(std.heap.page_allocator, "PATH") catch return .{};
        defer std.heap.page_allocator.free(path_var);
        return .{
            .shellcheck = findOnPathIn(path_var, "shellcheck"),
            .yamllint = findOnPathIn(path_var, "yamllint"),
            .ruff = findOnPathIn(path_var, "ruff"),
            .ty = findOnPathIn(path_var, "ty"),
            .tofu = findOnPathIn(path_var, "tofu"),
            .hadolint = findOnPathIn(path_var, "hadolint"),
            .actionlint = findOnPathIn(path_var, "actionlint"),
            .taplo = findOnPathIn(path_var, "taplo"),
            .nixfmt = findOnPathIn(path_var, "nixfmt"),
        };
    }
};

pub const FileContext = struct {
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
};

const max_tool_threads = 9;

const ToolType = enum {
    shellcheck,
    yamllint,
    ruff,
    ty,
    hadolint,
    actionlint,
    tofu,
    taplo,
    nixfmt,
};

fn createShadowContexts(allocator: std.mem.Allocator, originals: []const FileContext) ![]FileContext {
    const shadows = try allocator.alloc(FileContext, originals.len);
    for (originals, 0..) |ctx, i| {
        const diag_list = try allocator.create(std.ArrayList(Diagnostic));
        diag_list.* = .empty;
        shadows[i] = .{
            .path = ctx.path,
            .diags = diag_list,
            .existing_lines = ctx.existing_lines,
        };
    }
    return shadows;
}

fn toolThread(tool: ToolType, contexts: []FileContext, indices: []const usize) void {
    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = thread_arena.allocator();
    switch (tool) {
        .shellcheck => batchShellcheck(alloc, contexts, indices) catch {},
        .yamllint => batchYamllint(alloc, contexts, indices) catch {},
        .ruff => batchRuff(alloc, contexts, indices) catch {},
        .ty => batchTy(alloc, contexts, indices) catch {},
        .hadolint => batchHadolint(alloc, contexts, indices) catch {},
        .actionlint => batchActionlint(alloc, contexts, indices) catch {},
        .tofu => {
            for (indices) |idx| {
                runTofuFmt(alloc, contexts[idx].path, contexts[idx].diags) catch {};
            }
        },
        .taplo => {
            for (indices) |idx| {
                runTaploFmt(alloc, contexts[idx].path, contexts[idx].diags) catch {};
            }
        },
        .nixfmt => {
            for (indices) |idx| {
                runNixfmt(alloc, contexts[idx].path, contexts[idx].diags) catch {};
            }
        },
    }
}

fn spawnTool(
    allocator: std.mem.Allocator,
    threads: *[max_tool_threads]?std.Thread,
    shadow_sets: *[max_tool_threads]?[]FileContext,
    count: *usize,
    tool: ToolType,
    contexts: []const FileContext,
    indices: []const usize,
) void {
    if (indices.len == 0 or count.* >= max_tool_threads) return;
    const shadows = createShadowContexts(allocator, contexts) catch return;
    shadow_sets[count.*] = shadows;
    threads[count.*] = std.Thread.spawn(.{}, toolThread, .{ tool, shadows, indices }) catch {
        toolThread(tool, shadows, indices);
        count.* += 1;
        return;
    };
    count.* += 1;
}

/// Run external tools in parallel: one thread per tool type.
/// Each tool gets shadow diagnostic lists; results are merged after all complete.
pub fn runBatchedExternalTools(
    allocator: std.mem.Allocator,
    file_results: anytype,
    tools: ToolSet,
) !void {
    // Build file contexts with existing-line snapshots for dedup
    var contexts: std.ArrayList(FileContext) = .empty;
    for (file_results) |*fr| {
        var existing: std.ArrayList(u32) = .empty;
        for (fr.diags.items) |d| {
            try existing.append(allocator, d.line);
        }
        try contexts.append(allocator, .{
            .path = fr.path,
            .diags = &fr.diags,
            .existing_lines = existing.items,
        });
    }

    // Group file indices by tool type
    var shell_files: std.ArrayList(usize) = .empty;
    var yaml_files: std.ArrayList(usize) = .empty;
    var python_files: std.ArrayList(usize) = .empty;
    var hcl_files: std.ArrayList(usize) = .empty;
    var docker_files: std.ArrayList(usize) = .empty;
    var actions_files: std.ArrayList(usize) = .empty;
    var toml_files: std.ArrayList(usize) = .empty;
    var nix_files: std.ArrayList(usize) = .empty;

    for (contexts.items, 0..) |ctx, i| {
        if (isShellFile(ctx.path)) try shell_files.append(allocator, i);
        if (isYamlFile(ctx.path)) try yaml_files.append(allocator, i);
        if (isPythonFile(ctx.path)) try python_files.append(allocator, i);
        if (isHclFile(ctx.path)) try hcl_files.append(allocator, i);
        if (isDockerfile(ctx.path)) try docker_files.append(allocator, i);
        if (isGHActionsFile(ctx.path)) try actions_files.append(allocator, i);
        if (isTomlFile(ctx.path)) try toml_files.append(allocator, i);
        if (isNixFile(ctx.path)) try nix_files.append(allocator, i);
    }

    // Spawn one thread per enabled tool type
    var threads: [max_tool_threads]?std.Thread = .{null} ** max_tool_threads;
    var shadow_sets: [max_tool_threads]?[]FileContext = .{null} ** max_tool_threads;
    var thread_count: usize = 0;

    if (tools.shellcheck) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .shellcheck, contexts.items, shell_files.items);
    if (tools.yamllint) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .yamllint, contexts.items, yaml_files.items);
    if (tools.ruff) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .ruff, contexts.items, python_files.items);
    if (tools.ty) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .ty, contexts.items, python_files.items);
    if (tools.hadolint) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .hadolint, contexts.items, docker_files.items);
    if (tools.actionlint) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .actionlint, contexts.items, actions_files.items);
    if (tools.tofu) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .tofu, contexts.items, hcl_files.items);
    if (tools.taplo) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .taplo, contexts.items, toml_files.items);
    if (tools.nixfmt) spawnTool(allocator, &threads, &shadow_sets, &thread_count, .nixfmt, contexts.items, nix_files.items);

    // Join all threads
    for (&threads) |*t| {
        if (t.*) |thread| {
            thread.join();
            t.* = null;
        }
    }

    // Merge shadow diagnostics into real file contexts
    for (shadow_sets) |maybe_shadows| {
        const shadows = maybe_shadows orelse continue;
        for (contexts.items, shadows) |real_ctx, shadow_ctx| {
            for (shadow_ctx.diags.items) |diag| {
                try real_ctx.diags.append(allocator, diag);
            }
        }
    }
}

fn hasExternalFix(path: []const u8, tools: ToolSet) bool {
    return (tools.shellcheck and isShellFile(path)) or
        (tools.ruff and isPythonFile(path)) or
        (tools.tofu and isHclFile(path)) or
        (tools.taplo and isTomlFile(path)) or
        (tools.nixfmt and isNixFile(path));
}

fn fixThread(path: []const u8, tools: ToolSet) void {
    var thread_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    const alloc = thread_arena.allocator();
    runExternalFixes(alloc, path, tools);
}

/// Run external fixes in parallel: one thread per file.
/// Each file is independent (different path), so no synchronization needed.
pub fn runParallelExternalFixes(file_results: anytype, tools: ToolSet) void {
    var fix_threads: [256]?std.Thread = .{null} ** 256;
    var fix_count: usize = 0;

    for (file_results) |fr| {
        if (!hasExternalFix(fr.path, tools)) continue;
        if (fix_count >= 256) break;

        fix_threads[fix_count] = std.Thread.spawn(.{}, fixThread, .{ fr.path, tools }) catch {
            fixThread(fr.path, tools);
            continue;
        };
        fix_count += 1;
    }

    for (fix_threads[0..fix_count]) |maybe_t| {
        const t = maybe_t orelse continue;
        t.join();
    }
}

/// Maps shellcheck codes to jab rules for deduplication.
/// Returns the jab rule that covers the same issue, or null if no overlap.
fn shellcheckOverlap(sc_code: u32) ?RuleId {
    return switch (sc_code) {
        2086 => .bash_unquoted_var,
        2046 => .bash_unquoted_cmd_sub,
        2006 => .bash_backtick,
        2164 => .bash_cd_no_check,
        2068 => .bash_unquoted_at,
        else => null,
    };
}

fn runShellcheck(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "shellcheck", "-f", "json", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    // shellcheck exits 1 when it finds issues — that's expected
    if (result.stdout.len == 0) return;

    // Parse JSON array of diagnostics
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const code_val = obj.get("code") orelse continue;
        const code: u32 = switch (code_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        // Skip if jab already covers this rule
        if (shellcheckOverlap(code) != null) continue;

        const line_val = obj.get("line") orelse continue;
        const line: u32 = switch (line_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        const col_val = obj.get("column") orelse continue;
        const col: u32 = switch (col_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        // Skip if jab already reported on this exact line
        var already_reported = false;
        for (existing_lines) |el| {
            if (el == line) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        const message_val = obj.get("message") orelse continue;
        const message = switch (message_val) {
            .string => |s| s,
            else => continue,
        };

        const display = std.fmt.allocPrint(allocator, "SC{d}", .{code}) catch continue;

        try diags.append(allocator, .{
            .rule = .ext_shellcheck,
            .line = line,
            .col = col,
            .message = message,
            .display_name = display,
        });
    }
}

fn runTofuFmt(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tofu", "fmt", "-check", "-diff", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    // Exit 0 = already formatted, exit 3 = needs formatting
    const exit_code = switch (result.term) {
        .Exited => |c| c,
        else => return,
    };

    if (exit_code == 0) return;

    // tofu fmt -check exits non-zero if file needs formatting
    // Report a single diagnostic per file
    try diags.append(allocator, .{
        .rule = .ext_tofu_fmt,
        .line = 1,
        .col = 1,
        .message = "File needs formatting (run: tofu fmt)",
        .display_name = "tofu fmt",
    });
}

/// Maps ruff rule codes to jab rules for deduplication.
fn ruffOverlap(code: []const u8) ?RuleId {
    // E711: comparison to None
    if (std.mem.eql(u8, code, "E711")) return .py_none_equality;
    // E712: comparison to True/False
    if (std.mem.eql(u8, code, "E712")) return .py_bool_equality;
    // E722: bare except
    if (std.mem.eql(u8, code, "E722")) return .py_bare_except;
    return null;
}

fn runYamllint(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
) !void {
    // yamllint -f parsable outputs: path:line:col: [level] message (rule)
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "yamllint", "-f", "parsable", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0) continue;

        // Format: path:line:col: [level] message (rule)
        // Find line number after the path
        const after_path = std.mem.indexOf(u8, raw_line, ":");
        if (after_path == null) continue;
        const rest1 = raw_line[after_path.? + 1 ..];

        const line_end = std.mem.indexOf(u8, rest1, ":") orelse continue;
        const line_str = rest1[0..line_end];
        const line = std.fmt.parseInt(u32, line_str, 10) catch continue;

        const rest2 = rest1[line_end + 1 ..];
        const col_end = std.mem.indexOf(u8, rest2, ":") orelse continue;
        const col_str = rest2[0..col_end];
        const col = std.fmt.parseInt(u32, col_str, 10) catch 1;

        // Skip if jab already reported on this line
        var already_reported = false;
        for (existing_lines) |el| {
            if (el == line) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        // Extract message — everything after "] "
        const msg_start = std.mem.indexOf(u8, rest2, "] ") orelse continue;
        const message = std.mem.trim(u8, rest2[msg_start + 2 ..], " \r");
        if (message.len == 0) continue;

        // Extract rule name from parentheses at the end if present
        const display = if (std.mem.lastIndexOf(u8, message, "(")) |paren_start| blk: {
            if (std.mem.indexOf(u8, message[paren_start..], ")")) |_| {
                break :blk std.fmt.allocPrint(allocator, "yamllint/{s}", .{
                    message[paren_start + 1 .. message.len - 1],
                }) catch "yamllint";
            }
            break :blk @as([]const u8, "yamllint");
        } else "yamllint";

        try diags.append(allocator, .{
            .rule = .ext_yamllint,
            .line = line,
            .col = col,
            .message = message,
            .display_name = display,
        });
    }
}

fn runRuff(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
) !void {
    // ruff check --output-format=json
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ruff", "check", "--output-format=json", "--no-fix", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const code_val = obj.get("code") orelse continue;
        const code = switch (code_val) {
            .string => |s| s,
            else => continue,
        };

        // Skip if jab already covers this rule
        if (ruffOverlap(code) != null) continue;

        // Location is nested: {"location": {"row": N, "column": N}}
        const location = switch (obj.get("location") orelse continue) {
            .object => |o| o,
            else => continue,
        };

        const row_val = location.get("row") orelse continue;
        const line: u32 = switch (row_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        const col_val = location.get("column") orelse continue;
        const col: u32 = switch (col_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        // Skip if jab already reported on this line
        var already_reported = false;
        for (existing_lines) |el| {
            if (el == line) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        const message_val = obj.get("message") orelse continue;
        const message = switch (message_val) {
            .string => |s| s,
            else => continue,
        };

        try diags.append(allocator, .{
            .rule = .ext_ruff,
            .line = line,
            .col = col,
            .message = message,
            .display_name = code,
        });
    }
}

fn runTy(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
) !void {
    // ty check --output-format json <file>
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ty", "check", "--output-format", "json", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    // ty outputs JSON array of diagnostics
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const code_val = obj.get("code") orelse obj.get("rule");
        const code = if (code_val) |cv| switch (cv) {
            .string => |s| s,
            else => "ty",
        } else "ty";

        // Location: try "location.row/column" (like ruff) or "line/column" directly
        var line: u32 = 0;
        var col: u32 = 1;

        if (obj.get("location")) |loc_val| {
            const loc = switch (loc_val) {
                .object => |o| o,
                else => null,
            };
            if (loc) |l| {
                if (l.get("row")) |rv| {
                    line = switch (rv) {
                        .integer => |i| @intCast(@as(u64, @bitCast(i))),
                        else => 0,
                    };
                }
                if (l.get("column")) |cv| {
                    col = switch (cv) {
                        .integer => |i| @intCast(@as(u64, @bitCast(i))),
                        else => 1,
                    };
                }
            }
        }

        // Fallback: top-level line/column
        if (line == 0) {
            if (obj.get("line")) |lv| {
                line = switch (lv) {
                    .integer => |i| @intCast(@as(u64, @bitCast(i))),
                    else => 0,
                };
            }
        }
        if (line == 0) continue;

        // Skip if jab already reported on this line
        var already_reported = false;
        for (existing_lines) |el| {
            if (el == line) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        const message_val = obj.get("message") orelse continue;
        const message = switch (message_val) {
            .string => |s| s,
            else => continue,
        };

        try diags.append(allocator, .{
            .rule = .ext_ty,
            .line = line,
            .col = col,
            .message = message,
            .display_name = code,
        });
    }
}

fn runHadolint(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "hadolint", "-f", "json", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const line_val = obj.get("line") orelse continue;
        const line: u32 = switch (line_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        const col: u32 = if (obj.get("column")) |cv| switch (cv) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => 1,
        } else 1;

        var already_reported = false;
        for (existing_lines) |el| {
            if (el == line) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        const code = if (obj.get("code")) |cv| switch (cv) {
            .string => |s| s,
            else => "hadolint",
        } else "hadolint";

        const message_val = obj.get("message") orelse continue;
        const message = switch (message_val) {
            .string => |s| s,
            else => continue,
        };

        try diags.append(allocator, .{
            .rule = .ext_hadolint,
            .line = line,
            .col = col,
            .message = message,
            .display_name = code,
        });
    }
}

fn runActionlint(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
    existing_lines: []const u32,
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "actionlint", "-format", "{{json .}}", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const line_val = obj.get("line") orelse continue;
        const line: u32 = switch (line_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        const col: u32 = if (obj.get("column")) |cv| switch (cv) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => 1,
        } else 1;

        var already_reported = false;
        for (existing_lines) |el| {
            if (el == line) {
                already_reported = true;
                break;
            }
        }
        if (already_reported) continue;

        const message_val = obj.get("message") orelse continue;
        const message = switch (message_val) {
            .string => |s| s,
            else => continue,
        };

        const kind = if (obj.get("kind")) |kv| switch (kv) {
            .string => |s| s,
            else => null,
        } else null;

        const display = if (kind) |k|
            std.fmt.allocPrint(allocator, "actionlint/{s}", .{k}) catch "actionlint"
        else
            @as([]const u8, "actionlint");

        try diags.append(allocator, .{
            .rule = .ext_actionlint,
            .line = line,
            .col = col,
            .message = message,
            .display_name = display,
        });
    }
}

fn runTaploFmt(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "taplo", "fmt", "--check", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    const exit_code = switch (result.term) {
        .Exited => |c| c,
        else => return,
    };

    if (exit_code == 0) return;

    try diags.append(allocator, .{
        .rule = .ext_taplo,
        .line = 1,
        .col = 1,
        .message = "File needs formatting (run: taplo fmt)",
        .display_name = "taplo fmt",
    });
}

fn runNixfmt(
    allocator: std.mem.Allocator,
    path: []const u8,
    diags: *std.ArrayList(Diagnostic),
) !void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "nixfmt", "--check", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    const exit_code = switch (result.term) {
        .Exited => |c| c,
        else => return,
    };

    if (exit_code == 0) return;

    try diags.append(allocator, .{
        .rule = .ext_nixfmt,
        .line = 1,
        .col = 1,
        .message = "File needs formatting (run: nixfmt)",
        .display_name = "nixfmt",
    });
}

// --- Batched tool runners: one invocation for all matching files ---

fn findContextIdx(contexts: []const FileContext, file_path: []const u8) ?usize {
    for (contexts, 0..) |ctx, i| {
        if (std.mem.eql(u8, ctx.path, file_path)) return i;
    }
    return null;
}

fn isExistingLine(existing_lines: []const u32, line: u32) bool {
    for (existing_lines) |el| {
        if (el == line) return true;
    }
    return false;
}

fn batchShellcheck(
    allocator: std.mem.Allocator,
    contexts: []const FileContext,
    indices: []const usize,
) !void {
    // Build argv: shellcheck -f json file1 file2 ...
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "shellcheck");
    try argv.append(allocator, "-f");
    try argv.append(allocator, "json");
    for (indices) |idx| {
        try argv.append(allocator, contexts[idx].path);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const code_val = obj.get("code") orelse continue;
        const code: u32 = switch (code_val) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };
        if (shellcheckOverlap(code) != null) continue;

        const file_val = obj.get("file") orelse continue;
        const file = switch (file_val) {
            .string => |s| s,
            else => continue,
        };

        const line: u32 = switch ((obj.get("line") orelse continue)) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };
        const col: u32 = switch ((obj.get("column") orelse continue)) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        // Find matching context by file path
        const ctx_idx = findContextIdx(contexts, file) orelse continue;
        const ctx = contexts[ctx_idx];
        if (isExistingLine(ctx.existing_lines, line)) continue;

        const message = switch ((obj.get("message") orelse continue)) {
            .string => |s| s,
            else => continue,
        };

        const display = std.fmt.allocPrint(allocator, "SC{d}", .{code}) catch continue;
        try ctx.diags.append(allocator, .{
            .rule = .ext_shellcheck,
            .line = line,
            .col = col,
            .message = message,
            .display_name = display,
        });
    }
}

fn batchYamllint(
    allocator: std.mem.Allocator,
    contexts: []const FileContext,
    indices: []const usize,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "yamllint");
    try argv.append(allocator, "-f");
    try argv.append(allocator, "parsable");
    for (indices) |idx| {
        try argv.append(allocator, contexts[idx].path);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    var lines = std.mem.splitScalar(u8, result.stdout, '\n');
    while (lines.next()) |raw_line| {
        if (raw_line.len == 0) continue;

        // Format: path:line:col: [level] message (rule)
        // Need to find the file path — everything before the first ":N:" pattern
        const file_and_rest = parseYamllintLine(raw_line) orelse continue;
        const ctx_idx = findContextIdx(contexts, file_and_rest.file) orelse continue;
        const ctx = contexts[ctx_idx];

        if (isExistingLine(ctx.existing_lines, file_and_rest.line)) continue;

        const display = if (std.mem.lastIndexOf(u8, file_and_rest.message, "(")) |paren_start| blk: {
            if (std.mem.indexOf(u8, file_and_rest.message[paren_start..], ")")) |_| {
                break :blk std.fmt.allocPrint(allocator, "yamllint/{s}", .{
                    file_and_rest.message[paren_start + 1 .. file_and_rest.message.len - 1],
                }) catch "yamllint";
            }
            break :blk @as([]const u8, "yamllint");
        } else "yamllint";

        try ctx.diags.append(allocator, .{
            .rule = .ext_yamllint,
            .line = file_and_rest.line,
            .col = file_and_rest.col,
            .message = file_and_rest.message,
            .display_name = display,
        });
    }
}

const YamllintParsed = struct {
    file: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
};

fn parseYamllintLine(raw: []const u8) ?YamllintParsed {
    // yamllint parsable format: path:line:col: [level] message
    // Path may contain colons on some systems, so find ":N:" pattern
    var i: usize = 1;
    while (i < raw.len) {
        if (raw[i] == ':') {
            // Check if next chars are digits followed by ':'
            const rest = raw[i + 1 ..];
            const colon2 = std.mem.indexOf(u8, rest, ":") orelse {
                i += 1;
                continue;
            };
            const line_str = rest[0..colon2];
            const line = std.fmt.parseInt(u32, line_str, 10) catch {
                i += 1;
                continue;
            };
            const rest2 = rest[colon2 + 1 ..];
            const colon3 = std.mem.indexOf(u8, rest2, ":") orelse {
                i += 1;
                continue;
            };
            const col_str = rest2[0..colon3];
            const col = std.fmt.parseInt(u32, col_str, 10) catch 1;

            const msg_start = std.mem.indexOf(u8, rest2, "] ") orelse {
                i += 1;
                continue;
            };
            const message = std.mem.trim(u8, rest2[msg_start + 2 ..], " \r");
            if (message.len == 0) {
                i += 1;
                continue;
            }

            return .{
                .file = raw[0..i],
                .line = line,
                .col = col,
                .message = message,
            };
        }
        i += 1;
    }
    return null;
}

fn batchRuff(
    allocator: std.mem.Allocator,
    contexts: []const FileContext,
    indices: []const usize,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "ruff");
    try argv.append(allocator, "check");
    try argv.append(allocator, "--output-format=json");
    try argv.append(allocator, "--no-fix");
    for (indices) |idx| {
        try argv.append(allocator, contexts[idx].path);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const code = switch ((obj.get("code") orelse continue)) {
            .string => |s| s,
            else => continue,
        };
        if (ruffOverlap(code) != null) continue;

        const filename = switch ((obj.get("filename") orelse continue)) {
            .string => |s| s,
            else => continue,
        };

        const location = switch ((obj.get("location") orelse continue)) {
            .object => |o| o,
            else => continue,
        };
        const line: u32 = switch ((location.get("row") orelse continue)) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };
        const col: u32 = switch ((location.get("column") orelse continue)) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };

        const ctx_idx = findContextIdx(contexts, filename) orelse continue;
        const ctx = contexts[ctx_idx];
        if (isExistingLine(ctx.existing_lines, line)) continue;

        const message = switch ((obj.get("message") orelse continue)) {
            .string => |s| s,
            else => continue,
        };

        try ctx.diags.append(allocator, .{
            .rule = .ext_ruff,
            .line = line,
            .col = col,
            .message = message,
            .display_name = code,
        });
    }
}

fn batchTy(
    allocator: std.mem.Allocator,
    contexts: []const FileContext,
    indices: []const usize,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "ty");
    try argv.append(allocator, "check");
    try argv.append(allocator, "--output-format");
    try argv.append(allocator, "json");
    for (indices) |idx| {
        try argv.append(allocator, contexts[idx].path);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const code = if (obj.get("code") orelse obj.get("rule")) |cv| switch (cv) {
            .string => |s| s,
            else => "ty",
        } else "ty";

        // Try to get filename from "filename" or "file" field
        const filename = if (obj.get("filename")) |fv| switch (fv) {
            .string => |s| s,
            else => null,
        } else if (obj.get("file")) |fv| switch (fv) {
            .string => |s| s,
            else => null,
        } else null;

        var line: u32 = 0;
        var col: u32 = 1;

        if (obj.get("location")) |loc_val| {
            if (switch (loc_val) {
                .object => |o| o,
                else => null,
            }) |loc| {
                if (loc.get("row")) |rv| {
                    line = switch (rv) {
                        .integer => |i| @intCast(@as(u64, @bitCast(i))),
                        else => 0,
                    };
                }
                if (loc.get("column")) |cv| {
                    col = switch (cv) {
                        .integer => |i| @intCast(@as(u64, @bitCast(i))),
                        else => 1,
                    };
                }
            }
        }
        if (line == 0) {
            if (obj.get("line")) |lv| {
                line = switch (lv) {
                    .integer => |i| @intCast(@as(u64, @bitCast(i))),
                    else => 0,
                };
            }
        }
        if (line == 0) continue;

        // If only one file, use that; otherwise match by filename
        const ctx_idx = if (indices.len == 1)
            indices[0]
        else if (filename) |f|
            findContextIdx(contexts, f) orelse continue
        else
            continue;

        const ctx = contexts[ctx_idx];
        if (isExistingLine(ctx.existing_lines, line)) continue;

        const message = switch ((obj.get("message") orelse continue)) {
            .string => |s| s,
            else => continue,
        };

        try ctx.diags.append(allocator, .{
            .rule = .ext_ty,
            .line = line,
            .col = col,
            .message = message,
            .display_name = code,
        });
    }
}

fn batchHadolint(
    allocator: std.mem.Allocator,
    contexts: []const FileContext,
    indices: []const usize,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "hadolint");
    try argv.append(allocator, "-f");
    try argv.append(allocator, "json");
    for (indices) |idx| {
        try argv.append(allocator, contexts[idx].path);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const line: u32 = switch ((obj.get("line") orelse continue)) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };
        const col: u32 = if (obj.get("column")) |cv| switch (cv) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => 1,
        } else 1;

        const file = if (obj.get("file")) |fv| switch (fv) {
            .string => |s| s,
            else => null,
        } else null;

        const ctx_idx = if (indices.len == 1)
            indices[0]
        else if (file) |f|
            findContextIdx(contexts, f) orelse continue
        else
            continue;

        const ctx = contexts[ctx_idx];
        if (isExistingLine(ctx.existing_lines, line)) continue;

        const code_str = if (obj.get("code")) |cv| switch (cv) {
            .string => |s| s,
            else => "hadolint",
        } else "hadolint";

        const message = switch ((obj.get("message") orelse continue)) {
            .string => |s| s,
            else => continue,
        };

        try ctx.diags.append(allocator, .{
            .rule = .ext_hadolint,
            .line = line,
            .col = col,
            .message = message,
            .display_name = code_str,
        });
    }
}

fn batchActionlint(
    allocator: std.mem.Allocator,
    contexts: []const FileContext,
    indices: []const usize,
) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, "actionlint");
    try argv.append(allocator, "-format");
    try argv.append(allocator, "{{json .}}");
    for (indices) |idx| {
        try argv.append(allocator, contexts[idx].path);
    }

    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = argv.items,
        .max_output_bytes = 1024 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result.stdout, .{}) catch return;
    const items = switch (parsed.value) {
        .array => |a| a.items,
        else => return,
    };

    for (items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => continue,
        };

        const line: u32 = switch ((obj.get("line") orelse continue)) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => continue,
        };
        const col: u32 = if (obj.get("column")) |cv| switch (cv) {
            .integer => |i| @intCast(@as(u64, @bitCast(i))),
            else => 1,
        } else 1;

        const filepath = if (obj.get("filepath")) |fv| switch (fv) {
            .string => |s| s,
            else => null,
        } else null;

        const ctx_idx = if (indices.len == 1)
            indices[0]
        else if (filepath) |f|
            findContextIdx(contexts, f) orelse continue
        else
            continue;

        const ctx = contexts[ctx_idx];
        if (isExistingLine(ctx.existing_lines, line)) continue;

        const message = switch ((obj.get("message") orelse continue)) {
            .string => |s| s,
            else => continue,
        };

        const kind = if (obj.get("kind")) |kv| switch (kv) {
            .string => |s| s,
            else => null,
        } else null;

        const display = if (kind) |k|
            std.fmt.allocPrint(allocator, "actionlint/{s}", .{k}) catch "actionlint"
        else
            @as([]const u8, "actionlint");

        try ctx.diags.append(allocator, .{
            .rule = .ext_actionlint,
            .line = line,
            .col = col,
            .message = message,
            .display_name = display,
        });
    }
}

/// Run external tool auto-fixes on a file (in-place).
/// Called after jab's own fixes have been written.
pub fn runExternalFixes(allocator: std.mem.Allocator, path: []const u8, tools: ToolSet) void {
    if (tools.shellcheck and isShellFile(path)) {
        shellcheckFix(allocator, path);
    }
    if (tools.ruff and isPythonFile(path)) {
        ruffFix(allocator, path);
    }
    if (tools.tofu and isHclFile(path)) {
        tofuFix(allocator, path);
    }
    if (tools.taplo and isTomlFile(path)) {
        taploFix(allocator, path);
    }
    if (tools.nixfmt and isNixFile(path)) {
        nixfmtFix(allocator, path);
    }
}

fn shellcheckFix(allocator: std.mem.Allocator, path: []const u8) void {
    const result = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "shellcheck", "-f", "diff", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;

    if (result.stdout.len == 0) return;

    const source = std.fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return;
    const fixed = applyDiff(allocator, source, result.stdout) orelse return;

    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(fixed) catch {};
}

fn ruffFix(allocator: std.mem.Allocator, path: []const u8) void {
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "ruff", "check", "--fix", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;
}

fn tofuFix(allocator: std.mem.Allocator, path: []const u8) void {
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "tofu", "fmt", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;
}

fn taploFix(allocator: std.mem.Allocator, path: []const u8) void {
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "taplo", "fmt", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;
}

fn nixfmtFix(allocator: std.mem.Allocator, path: []const u8) void {
    _ = std.process.Child.run(.{
        .allocator = allocator,
        .argv = &.{ "nixfmt", path },
        .max_output_bytes = 256 * 1024,
    }) catch return;
}

/// Apply a unified diff to source text. Returns patched output or null on failure.
fn applyDiff(allocator: std.mem.Allocator, source: []const u8, diff: []const u8) ?[]const u8 {
    const Hunk = struct {
        old_start: usize,
        old_count: usize,
        new_lines: std.ArrayList([]const u8),
    };

    // Split source into lines
    var src_lines: std.ArrayList([]const u8) = .empty;
    var src_iter = std.mem.splitScalar(u8, source, '\n');
    while (src_iter.next()) |line| {
        src_lines.append(allocator, line) catch return null;
    }

    // Parse hunks
    var hunks: std.ArrayList(Hunk) = .empty;
    var current: ?Hunk = null;

    var diff_iter = std.mem.splitScalar(u8, diff, '\n');
    while (diff_iter.next()) |dline| {
        if (std.mem.startsWith(u8, dline, "@@ ")) {
            // Save previous hunk
            if (current) |h| {
                hunks.append(allocator, h) catch return null;
            }
            // Parse "@@ -A,B +C,D @@"
            const after_minus = std.mem.indexOf(u8, dline[3..], "-") orelse continue;
            const nums = dline[3 + after_minus + 1 ..];
            const space = std.mem.indexOf(u8, nums, " ") orelse continue;
            const old_spec = nums[0..space];

            var old_start: usize = 0;
            var old_count: usize = 1;
            if (std.mem.indexOf(u8, old_spec, ",")) |comma| {
                old_start = std.fmt.parseInt(usize, old_spec[0..comma], 10) catch continue;
                old_count = std.fmt.parseInt(usize, old_spec[comma + 1 ..], 10) catch continue;
            } else {
                old_start = std.fmt.parseInt(usize, old_spec, 10) catch continue;
            }

            current = .{
                .old_start = old_start,
                .old_count = old_count,
                .new_lines = .empty,
            };
        } else if (current != null) {
            if (dline.len == 0) continue;
            switch (dline[0]) {
                ' ' => current.?.new_lines.append(allocator, dline[1..]) catch return null,
                '+' => current.?.new_lines.append(allocator, dline[1..]) catch return null,
                '-' => {},
                '\\' => {},
                else => {},
            }
        }
    }
    if (current) |h| {
        hunks.append(allocator, h) catch return null;
    }

    if (hunks.items.len == 0) return null;

    // Sort ascending by old_start
    std.mem.sortUnstable(Hunk, hunks.items, {}, struct {
        fn lessThan(_: void, a: Hunk, b: Hunk) bool {
            return a.old_start < b.old_start;
        }
    }.lessThan);

    // Build result by splicing hunks into source lines
    var result: std.ArrayList([]const u8) = .empty;
    var pos: usize = 0;

    for (hunks.items) |hunk| {
        const start = hunk.old_start -| 1; // 0-based, saturating
        // Copy lines before this hunk
        while (pos < start and pos < src_lines.items.len) : (pos += 1) {
            result.append(allocator, src_lines.items[pos]) catch return null;
        }
        // Insert replacement lines
        for (hunk.new_lines.items) |nl| {
            result.append(allocator, nl) catch return null;
        }
        // Skip old lines
        pos = start + hunk.old_count;
    }
    // Copy remaining source lines
    while (pos < src_lines.items.len) : (pos += 1) {
        result.append(allocator, src_lines.items[pos]) catch return null;
    }

    // Join with newlines
    var out: std.ArrayList(u8) = .empty;
    for (result.items, 0..) |line, idx| {
        out.appendSlice(allocator, line) catch return null;
        if (idx < result.items.len - 1) {
            out.append(allocator, '\n') catch return null;
        }
    }

    return out.items;
}

test "applyDiff basic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const source = "line1\nline2\nline3\n";
    const diff =
        \\--- a/test.sh
        \\+++ b/test.sh
        \\@@ -2,1 +2,1 @@
        \\-line2
        \\+fixed2
        \\
    ;
    const result = applyDiff(allocator, source, diff);
    try std.testing.expect(result != null);
    try std.testing.expectEqualStrings("line1\nfixed2\nline3\n", result.?);
}

test "shellcheckOverlap" {
    try std.testing.expectEqual(RuleId.bash_unquoted_var, shellcheckOverlap(2086).?);
    try std.testing.expectEqual(RuleId.bash_backtick, shellcheckOverlap(2006).?);
    try std.testing.expectEqual(@as(?RuleId, null), shellcheckOverlap(1234));
}

test "isShellFile" {
    try std.testing.expect(isShellFile("foo.sh"));
    try std.testing.expect(isShellFile("bar.bash"));
    try std.testing.expect(!isShellFile("baz.py"));
}

test "isHclFile" {
    try std.testing.expect(isHclFile("main.tf"));
    try std.testing.expect(isHclFile("vars.tfvars"));
    try std.testing.expect(!isHclFile("foo.json"));
}

test "isYamlFile" {
    try std.testing.expect(isYamlFile("config.yaml"));
    try std.testing.expect(isYamlFile("ci.yml"));
    try std.testing.expect(!isYamlFile("data.json"));
}

test "isPythonFile" {
    try std.testing.expect(isPythonFile("main.py"));
    try std.testing.expect(isPythonFile("types.pyi"));
    try std.testing.expect(!isPythonFile("script.sh"));
}

test "isDockerfile" {
    try std.testing.expect(isDockerfile("Dockerfile"));
    try std.testing.expect(isDockerfile("Dockerfile.prod"));
    try std.testing.expect(isDockerfile("path/to/Dockerfile"));
    try std.testing.expect(isDockerfile("app.dockerfile"));
    try std.testing.expect(isDockerfile("Containerfile"));
    try std.testing.expect(!isDockerfile("main.py"));
}

test "isGHActionsFile" {
    try std.testing.expect(isGHActionsFile(".github/workflows/ci.yml"));
    try std.testing.expect(isGHActionsFile(".github/workflows/deploy.yaml"));
    try std.testing.expect(!isGHActionsFile(".github/dependabot.yml"));
    try std.testing.expect(!isGHActionsFile("workflows/ci.yml"));
}

test "isTomlFile" {
    try std.testing.expect(isTomlFile("pyproject.toml"));
    try std.testing.expect(isTomlFile("Cargo.toml"));
    try std.testing.expect(!isTomlFile("config.yaml"));
}

test "isNixFile" {
    try std.testing.expect(isNixFile("flake.nix"));
    try std.testing.expect(isNixFile("default.nix"));
    try std.testing.expect(!isNixFile("flake.lock"));
}

test "ruffOverlap" {
    try std.testing.expectEqual(RuleId.py_bare_except, ruffOverlap("E722").?);
    try std.testing.expectEqual(RuleId.py_none_equality, ruffOverlap("E711").?);
    try std.testing.expectEqual(@as(?RuleId, null), ruffOverlap("F401"));
}
