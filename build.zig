const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug symbols from the binary") orelse false;

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });

    addTreeSitter(b, exe_mod);

    const exe = b.addExecutable(.{
        .name = "jab",
        .root_module = exe_mod,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run jab");
    run_step.dependOn(&run_cmd.step);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    addTreeSitter(b, test_mod);

    const tests = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);
}

fn addTreeSitter(b: *std.Build, mod: *std.Build.Module) void {
    mod.link_libc = true;

    mod.addIncludePath(b.path("vendor/tree-sitter/lib/include"));
    mod.addIncludePath(b.path("vendor/tree-sitter/lib/src"));

    mod.addCSourceFile(.{
        .file = b.path("vendor/tree-sitter/lib/src/lib.c"),
        .flags = &.{
            "-std=c11",
            "-DTREE_SITTER_HIDE_SYMBOLS",
            "-DTREE_SITTER_NO_WASM",
            "-D_POSIX_C_SOURCE=200112L",
            "-D_DEFAULT_SOURCE",
            "-fno-exceptions",
        },
    });

    mod.addIncludePath(b.path("grammars/bash/src"));

    mod.addCSourceFile(.{
        .file = b.path("grammars/bash/src/parser.c"),
        .flags = &.{ "-std=c11", "-fno-exceptions" },
    });

    mod.addCSourceFile(.{
        .file = b.path("grammars/bash/src/scanner.c"),
        .flags = &.{ "-std=c11", "-fno-exceptions" },
    });

    mod.addIncludePath(b.path("grammars/python/src"));

    mod.addCSourceFile(.{
        .file = b.path("grammars/python/src/parser.c"),
        .flags = &.{ "-std=c11", "-fno-exceptions" },
    });

    mod.addCSourceFile(.{
        .file = b.path("grammars/python/src/scanner.c"),
        .flags = &.{ "-std=c11", "-fno-exceptions" },
    });

    mod.addIncludePath(b.path("grammars/hcl/src"));

    mod.addCSourceFile(.{
        .file = b.path("grammars/hcl/src/parser.c"),
        .flags = &.{ "-std=c11", "-fno-exceptions" },
    });

    mod.addCSourceFile(.{
        .file = b.path("grammars/hcl/src/scanner.c"),
        .flags = &.{ "-std=c11", "-fno-exceptions" },
    });
}
