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
