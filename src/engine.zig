const std = @import("std");
const diagnostic = @import("diagnostic.zig");

pub const FixResult = diagnostic.FixResult;
pub const SkipSet = diagnostic.SkipSet;
pub const Diagnostic = diagnostic.Diagnostic;
pub const DiagnosticList = diagnostic.DiagnosticList;
pub const RuleId = diagnostic.RuleId;

pub const Engine = struct {
    extensions: []const []const u8,
    fixFn: *const fn (std.mem.Allocator, []const u8, []const u8, SkipSet, bool) FixResult,
};

pub const json = @import("engine/json.zig");
pub const bash = @import("engine/bash.zig");
pub const yaml = @import("engine/yaml.zig");
pub const python = @import("engine/python.zig");
pub const hcl = @import("engine/hcl.zig");
pub const markdown = @import("engine/markdown.zig");
pub const toml = @import("engine/toml.zig");

pub const registry = [_]struct {
    extensions: []const []const u8,
    engine: type,
}{
    .{
        .extensions = &.{ ".json", ".jsonc" },
        .engine = json,
    },
    .{
        .extensions = &.{ ".sh", ".bash" },
        .engine = bash,
    },
    .{
        .extensions = &.{ ".yaml", ".yml" },
        .engine = yaml,
    },
    .{
        .extensions = &.{ ".py", ".pyi" },
        .engine = python,
    },
    .{
        .extensions = &.{ ".tf", ".tfvars", ".hcl", ".tofu" },
        .engine = hcl,
    },
    .{
        .extensions = &.{".md"},
        .engine = markdown,
    },
    .{
        .extensions = &.{".toml"},
        .engine = toml,
    },
};

pub fn findEngine(path: []const u8) ?type {
    inline for (registry) |entry| {
        for (entry.extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) {
                return entry.engine;
            }
        }
    }
    return null;
}

test "findEngine matches json" {
    try std.testing.expect(findEngine("foo.json") == json);
    try std.testing.expect(findEngine("bar.jsonc") == json);
}

test "findEngine matches bash" {
    try std.testing.expect(findEngine("script.sh") == bash);
    try std.testing.expect(findEngine("run.bash") == bash);
}

test "findEngine matches yaml" {
    try std.testing.expect(findEngine("config.yaml") == yaml);
    try std.testing.expect(findEngine("config.yml") == yaml);
}

test "findEngine matches python" {
    try std.testing.expect(findEngine("app.py") == python);
    try std.testing.expect(findEngine("stubs.pyi") == python);
}

test "findEngine matches hcl" {
    try std.testing.expect(findEngine("main.tf") == hcl);
    try std.testing.expect(findEngine("vars.tfvars") == hcl);
    try std.testing.expect(findEngine("config.hcl") == hcl);
    try std.testing.expect(findEngine("main.tofu") == hcl);
}

test "findEngine matches markdown" {
    try std.testing.expect(findEngine("readme.md") == markdown);
}

test "findEngine matches toml" {
    try std.testing.expect(findEngine("config.toml") == toml);
}

test "findEngine returns null for unknown" {
    try std.testing.expect(findEngine("main.zig") == null);
    try std.testing.expect(findEngine("Makefile") == null);
}

pub fn processFile(
    allocator: std.mem.Allocator,
    source: []const u8,
    path: []const u8,
    skip: SkipSet,
    dry_run: bool,
) ?FixResult {
    inline for (registry) |entry| {
        for (entry.extensions) |ext| {
            if (std.mem.endsWith(u8, path, ext)) {
                return entry.engine.fix(allocator, source, path, skip, dry_run);
            }
        }
    }
    return null;
}
