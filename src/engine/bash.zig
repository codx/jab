const std = @import("std");
const diagnostic = @import("../diagnostic.zig");
const indent_mod = @import("../indent.zig");
const ts = @import("../treesitter.zig");
const RuleId = diagnostic.RuleId;
const Diagnostic = diagnostic.Diagnostic;
const DiagnosticList = diagnostic.DiagnosticList;
const SkipSet = diagnostic.SkipSet;
const FixResult = diagnostic.FixResult;

pub fn fix(
    allocator: std.mem.Allocator,
    source: []const u8,
    _: []const u8,
    skip: SkipSet,
    dry_run: bool,
) FixResult {
    var diags: DiagnosticList = .{};

    const parser = ts.Parser.init() orelse return noChange(source, &diags);
    defer parser.deinit();
    _ = parser.setLanguage(ts.languages.bash());

    const tree = parser.parse(source) orelse return noChange(source, &diags);
    defer ts.freeTree(tree);

    var replacements: std.ArrayList(Replacement) = .empty;

    var cursor = ts.cursorNew(ts.rootNode(tree));
    defer ts.cursorDelete(&cursor);

    visitNodes(&cursor, source, skip, allocator, &diags, &replacements);

    if (dry_run or replacements.items.len == 0) {
        return .{
            .output = source,
            .diagnostics = diags.slice(),
            .changed = false,
        };
    }

    const output = applyReplacements(allocator, source, replacements.items) orelse source;
    return .{
        .output = output,
        .diagnostics = diags.slice(),
        .changed = !std.mem.eql(u8, output, source),
    };
}

const Replacement = struct {
    start: u32,
    end: u32,
    text: []const u8,
};

fn visitNodes(
    cursor: *ts.TreeCursor,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    var reached_root = false;
    while (!reached_root) {
        const node = ts.cursorNode(cursor);
        checkNode(node, source, skip, allocator, diags, replacements);

        if (ts.cursorGotoFirstChild(cursor)) continue;
        if (ts.cursorGotoNextSibling(cursor)) continue;

        var retracting = true;
        while (retracting) {
            if (!ts.cursorGotoParent(cursor)) {
                retracting = false;
                reached_root = true;
            } else {
                if (ts.cursorGotoNextSibling(cursor)) {
                    retracting = false;
                }
            }
        }
    }
}

fn checkNode(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    const node_type = ts.nodeType(node);

    if (std.mem.eql(u8, node_type, "simple_expansion") or
        std.mem.eql(u8, node_type, "expansion"))
    {
        checkUnquotedExpansion(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "command_substitution")) {
        checkUnquotedCommandSub(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "command_substitution")) {
        checkBacktickSyntax(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "command")) {
        checkCdWithoutErrorHandling(node, source, skip, allocator, diags, replacements);
        checkReadWithoutR(node, source, skip, allocator, diags);
        checkTestDoubleEq(node, source, skip, allocator, diags, replacements);
    }

    if (std.mem.eql(u8, node_type, "test_command")) {
        checkTestDoubleEq(node, source, skip, allocator, diags, replacements);
        checkTestAndOr(node, source, skip, allocator, diags);
    }

    if (std.mem.eql(u8, node_type, "simple_expansion") or
        std.mem.eql(u8, node_type, "expansion"))
    {
        checkDollarQuestion(node, source, skip, allocator, diags);
    }

    if (std.mem.eql(u8, node_type, "declaration_command")) {
        checkLocalMaskReturn(node, source, skip, allocator, diags);
    }
}

fn checkUnquotedExpansion(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    const parent = ts.nodeParent(node);
    if (ts.nodeIsNull(parent)) return;
    const parent_type = ts.nodeType(parent);

    if (std.mem.eql(u8, parent_type, "string")) return;
    if (std.mem.eql(u8, parent_type, "variable_assignment")) return;
    if (std.mem.eql(u8, parent_type, "binary_expression")) {
        if (isInsideTestCommand(parent, source)) return;
    }
    if (isInsideArithmetic(node)) return;
    if (std.mem.eql(u8, parent_type, "array")) return;
    if (std.mem.eql(u8, parent_type, "case_item")) return;
    if (isInsideHeredoc(node)) return;

    const text = ts.nodeText(node, source);
    if (text.len == 0) return;

    if (std.mem.eql(u8, text, "$@") or std.mem.eql(u8, text, "${@}")) {
        if (skip.shouldSkip(.bash_unquoted_at)) return;
        const point = ts.nodeStartPoint(node);
        diags.add(allocator, .{
            .rule = .bash_unquoted_at,
            .line = point.row + 1,
            .col = point.column + 1,
            .message = "Unquoted $@",
            .span_len = @intCast(text.len),
            .suggestion = "Use \"$@\"",
        }) catch {};
        const start = ts.nodeStartByte(node);
        const end = ts.nodeEndByte(node);
        const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{text}) catch return;
        replacements.append(allocator, .{ .start = start, .end = end, .text = quoted }) catch {};
        return;
    }

    if (skip.shouldSkip(.bash_unquoted_var)) return;
    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_unquoted_var,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Unquoted variable expansion",
        .span_len = @intCast(text.len),
        .suggestion = "Quote with double quotes",
    }) catch {};

    const start = ts.nodeStartByte(node);
    const end = ts.nodeEndByte(node);
    const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{text}) catch return;
    replacements.append(allocator, .{ .start = start, .end = end, .text = quoted }) catch {};
}

fn checkUnquotedCommandSub(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_unquoted_cmd_sub)) return;

    const parent = ts.nodeParent(node);
    if (ts.nodeIsNull(parent)) return;
    const parent_type = ts.nodeType(parent);
    if (std.mem.eql(u8, parent_type, "string")) return;
    if (std.mem.eql(u8, parent_type, "variable_assignment")) return;
    if (isInsideArithmetic(node)) return;
    if (isInsideHeredoc(node)) return;

    const text = ts.nodeText(node, source);
    if (text.len == 0) return;
    if (text[0] == '`') return;

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_unquoted_cmd_sub,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Unquoted command substitution",
        .span_len = @intCast(text.len),
        .suggestion = "Quote with double quotes",
    }) catch {};

    const start = ts.nodeStartByte(node);
    const end = ts.nodeEndByte(node);
    const quoted = std.fmt.allocPrint(allocator, "\"{s}\"", .{text}) catch return;
    replacements.append(allocator, .{ .start = start, .end = end, .text = quoted }) catch {};
}

fn checkBacktickSyntax(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_backtick)) return;

    const text = ts.nodeText(node, source);
    if (text.len == 0 or text[0] != '`') return;

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_backtick,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Legacy backtick syntax",
        .span_len = @intCast(text.len),
        .suggestion = "Use $(...) instead",
    }) catch {};

    if (text.len >= 2 and text[0] == '`' and text[text.len - 1] == '`') {
        const inner = text[1 .. text.len - 1];
        const replacement = std.fmt.allocPrint(allocator, "$({s})", .{inner}) catch return;
        const start = ts.nodeStartByte(node);
        const end = ts.nodeEndByte(node);
        replacements.append(allocator, .{ .start = start, .end = end, .text = replacement }) catch {};
    }
}

fn checkCdWithoutErrorHandling(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    _: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_cd_no_check)) return;

    const child_count = ts.nodeChildCount(node);
    if (child_count == 0) return;

    const first_child = ts.nodeChild(node, 0);
    const cmd_name = ts.nodeText(first_child, source);
    if (!std.mem.eql(u8, cmd_name, "cd")) return;

    const parent = ts.nodeParent(node);
    if (!ts.nodeIsNull(parent)) {
        const parent_type = ts.nodeType(parent);
        if (std.mem.eql(u8, parent_type, "list")) {
            const pcount = ts.nodeChildCount(parent);
            var ci: u32 = 0;
            while (ci < pcount) : (ci += 1) {
                const sibling = ts.nodeChild(parent, ci);
                const stype = ts.nodeType(sibling);
                if (std.mem.eql(u8, stype, "||") or std.mem.eql(u8, stype, "&&")) return;
            }
        }
        if (std.mem.eql(u8, parent_type, "if_statement") or
            std.mem.eql(u8, parent_type, "subshell"))
        {
            return;
        }
    }

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_cd_no_check,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "cd without error handling",
        .span_len = @intCast(ts.nodeEndByte(node) - ts.nodeStartByte(node)),
        .suggestion = "Add || exit 1",
    }) catch {};
}

/// SC2162: read without -r will mangle backslashes
fn checkReadWithoutR(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
) void {
    if (skip.shouldSkip(.bash_read_no_r)) return;

    const child_count = ts.nodeChildCount(node);
    if (child_count == 0) return;

    const first_child = ts.nodeChild(node, 0);
    const cmd_name = ts.nodeText(first_child, source);
    if (!std.mem.eql(u8, cmd_name, "read")) return;

    // Check if any argument is -r or starts with -r (e.g. -rp)
    var i: u32 = 1;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const text = ts.nodeText(child, source);
        if (text.len > 0 and text[0] == '-') {
            if (std.mem.indexOfScalar(u8, text, 'r') != null) return;
        }
    }

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_read_no_r,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "read without -r will mangle backslashes",
        .span_len = @intCast(ts.nodeEndByte(node) - ts.nodeStartByte(node)),
        .suggestion = "Use read -r",
    }) catch {};
}

/// SC2155: Declare and assign separately to avoid masking return values
fn checkLocalMaskReturn(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
) void {
    if (skip.shouldSkip(.bash_local_mask_return)) return;

    // Check first child is "local", "declare", "export", "readonly"
    const child_count = ts.nodeChildCount(node);
    if (child_count < 2) return;

    const first_child = ts.nodeChild(node, 0);
    const keyword = ts.nodeText(first_child, source);
    if (!std.mem.eql(u8, keyword, "local") and
        !std.mem.eql(u8, keyword, "declare") and
        !std.mem.eql(u8, keyword, "readonly") and
        !std.mem.eql(u8, keyword, "export"))
        return;

    // Check if any child is a variable_assignment containing a command_substitution
    var i: u32 = 1;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        if (std.mem.eql(u8, ts.nodeType(child), "variable_assignment")) {
            if (containsCommandSub(child)) {
                const point = ts.nodeStartPoint(node);
                diags.add(allocator, .{
                    .rule = .bash_local_mask_return,
                    .line = point.row + 1,
                    .col = point.column + 1,
                    .message = std.fmt.allocPrint(allocator, "{s} assignment masks return value of command substitution", .{keyword}) catch "local assignment masks return value",
                    .span_len = @intCast(ts.nodeEndByte(node) - ts.nodeStartByte(node)),
                    .suggestion = "Declare and assign separately",
                }) catch {};
                return;
            }
        }
    }
}

fn containsCommandSub(node: ts.Node) bool {
    const child_count = ts.nodeChildCount(node);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const ntype = ts.nodeType(child);
        if (std.mem.eql(u8, ntype, "command_substitution")) return true;
        if (containsCommandSub(child)) return true;
    }
    return false;
}

/// SC2039/SC2169: == in [ ] test is not POSIX, use =
fn checkTestDoubleEq(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    if (skip.shouldSkip(.bash_test_double_eq)) return;

    const node_text = ts.nodeText(node, source);

    // Only flag single [ ] or test, not [[ ]] (where == is valid for pattern matching)
    if (std.mem.startsWith(u8, node_text, "[[")) return;
    if (!std.mem.startsWith(u8, node_text, "[") and !std.mem.startsWith(u8, node_text, "test ")) return;

    // Scan child nodes for == operator
    const child_count = ts.nodeChildCount(node);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const text = ts.nodeText(child, source);
        if (std.mem.eql(u8, text, "==")) {
            const point = ts.nodeStartPoint(child);
            diags.add(allocator, .{
                .rule = .bash_test_double_eq,
                .line = point.row + 1,
                .col = point.column + 1,
                .message = "== in [ ] is not POSIX",
                .span_len = 2,
                .suggestion = "Use = instead",
            }) catch {};

            const start = ts.nodeStartByte(child);
            const end = ts.nodeEndByte(child);
            replacements.append(allocator, .{ .start = start, .end = end, .text = "=" }) catch {};
        }
        // Also recurse into binary_expression children (test_command may nest)
        if (std.mem.eql(u8, ts.nodeType(child), "binary_expression")) {
            checkBinaryExprForDoubleEq(child, source, allocator, diags, replacements);
        }
    }
}

fn checkBinaryExprForDoubleEq(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
    replacements: *std.ArrayList(Replacement),
) void {
    const child_count = ts.nodeChildCount(node);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const text = ts.nodeText(child, source);
        if (std.mem.eql(u8, text, "==")) {
            const point = ts.nodeStartPoint(child);
            diags.add(allocator, .{
                .rule = .bash_test_double_eq,
                .line = point.row + 1,
                .col = point.column + 1,
                .message = "== in [ ] is not POSIX",
                .span_len = 2,
                .suggestion = "Use = instead",
            }) catch {};

            const start = ts.nodeStartByte(child);
            const end = ts.nodeEndByte(child);
            replacements.append(allocator, .{ .start = start, .end = end, .text = "=" }) catch {};
        }
    }
}

/// SC2181: Check exit code directly with e.g. `if mycmd;`, not indirectly with `$?`
fn checkDollarQuestion(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
) void {
    if (skip.shouldSkip(.bash_dollar_question)) return;

    const text = ts.nodeText(node, source);
    if (!std.mem.eql(u8, text, "$?") and !std.mem.eql(u8, text, "${?}")) return;

    // Only flag when inside a test/comparison context
    const parent = ts.nodeParent(node);
    if (ts.nodeIsNull(parent)) return;
    const parent_type = ts.nodeType(parent);
    if (!std.mem.eql(u8, parent_type, "binary_expression") and
        !std.mem.eql(u8, parent_type, "test_command") and
        !std.mem.eql(u8, parent_type, "command"))
        return;

    const point = ts.nodeStartPoint(node);
    diags.add(allocator, .{
        .rule = .bash_dollar_question,
        .line = point.row + 1,
        .col = point.column + 1,
        .message = "Use direct if statement instead of comparing $?",
        .span_len = @intCast(text.len),
        .suggestion = "Use if cmd; then ... instead",
    }) catch {};
}

/// SC2166: -a/-o in [ ] is not POSIX, use && / ||
fn checkTestAndOr(
    node: ts.Node,
    source: []const u8,
    skip: SkipSet,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
) void {
    if (skip.shouldSkip(.bash_test_and_or)) return;

    const node_text = ts.nodeText(node, source);

    // Only flag single [ ] or test, not [[ ]]
    if (std.mem.startsWith(u8, node_text, "[[")) return;
    if (!std.mem.startsWith(u8, node_text, "[") and !std.mem.startsWith(u8, node_text, "test ")) return;

    // Recursively search for test_operator nodes with -a/-o inside binary_expression
    findAndOrOperators(node, source, allocator, diags);
}

fn findAndOrOperators(
    node: ts.Node,
    source: []const u8,
    allocator: std.mem.Allocator,
    diags: *DiagnosticList,
) void {
    const child_count = ts.nodeChildCount(node);
    var i: u32 = 0;
    while (i < child_count) : (i += 1) {
        const child = ts.nodeChild(node, i);
        const ntype = ts.nodeType(child);
        const text = ts.nodeText(child, source);

        // test_operator with -a/-o inside a binary_expression = compound test
        if (std.mem.eql(u8, ntype, "test_operator") and
            (std.mem.eql(u8, text, "-a") or std.mem.eql(u8, text, "-o")))
        {
            // Confirm parent is binary_expression (not unary like [ -a file ])
            const parent = ts.nodeParent(child);
            if (!ts.nodeIsNull(parent) and std.mem.eql(u8, ts.nodeType(parent), "binary_expression")) {
                const point = ts.nodeStartPoint(child);
                diags.add(allocator, .{
                    .rule = .bash_test_and_or,
                    .line = point.row + 1,
                    .col = point.column + 1,
                    .message = if (std.mem.eql(u8, text, "-a"))
                        "-a in [ ] is not POSIX, use [ x ] && [ y ]"
                    else
                        "-o in [ ] is not POSIX, use [ x ] || [ y ]",
                    .span_len = 2,
                    .suggestion = if (std.mem.eql(u8, text, "-a")) "Use && instead" else "Use || instead",
                }) catch {};
            }
        }

        // Recurse into children
        findAndOrOperators(child, source, allocator, diags);
    }
}

fn isInsideTestCommand(node: ts.Node, source: []const u8) bool {
    var current = node;
    while (!ts.nodeIsNull(current)) {
        const ntype = ts.nodeType(current);
        if (std.mem.eql(u8, ntype, "test_command")) return true;
        if (std.mem.eql(u8, ntype, "command")) {
            const child_count = ts.nodeChildCount(current);
            if (child_count > 0) {
                const first = ts.nodeChild(current, 0);
                const text = ts.nodeText(first, source);
                if (std.mem.eql(u8, text, "[") or std.mem.eql(u8, text, "test")) return true;
            }
        }
        current = ts.nodeParent(current);
    }
    return false;
}

fn isInsideArithmetic(node: ts.Node) bool {
    var current = node;
    while (!ts.nodeIsNull(current)) {
        const ntype = ts.nodeType(current);
        if (std.mem.eql(u8, ntype, "arithmetic_expansion")) return true;
        current = ts.nodeParent(current);
    }
    return false;
}

fn isInsideHeredoc(node: ts.Node) bool {
    var current = node;
    while (!ts.nodeIsNull(current)) {
        const ntype = ts.nodeType(current);
        if (std.mem.eql(u8, ntype, "heredoc_body")) return true;
        if (std.mem.eql(u8, ntype, "heredoc_redirect")) return true;
        current = ts.nodeParent(current);
    }
    return false;
}

fn applyReplacements(allocator: std.mem.Allocator, source: []const u8, replacements: []const Replacement) ?[]const u8 {
    var sorted: std.ArrayList(Replacement) = .empty;
    sorted.appendSlice(allocator, replacements) catch return null;
    std.mem.sortUnstable(Replacement, sorted.items, {}, struct {
        fn lessThan(_: void, a: Replacement, b: Replacement) bool {
            return a.start < b.start;
        }
    }.lessThan);

    var result: std.ArrayList(u8) = .empty;
    var pos: u32 = 0;
    for (sorted.items) |r| {
        if (r.start < pos) continue;
        result.appendSlice(allocator, source[pos..r.start]) catch return null;
        result.appendSlice(allocator, r.text) catch return null;
        pos = r.end;
    }
    result.appendSlice(allocator, source[pos..]) catch return null;
    return result.items;
}

fn noChange(source: []const u8, diags: *DiagnosticList) FixResult {
    return .{
        .output = source,
        .diagnostics = diags.slice(),
        .changed = false,
    };
}

test "JB1003 backtick detection" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nfoo=`echo hello`\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_backtick) found = true;
    }
    try std.testing.expect(found);
}

test "JB1004 cd without error handling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\ncd /tmp\necho done\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_cd_no_check) found = true;
    }
    try std.testing.expect(found);
}

test "JB1004 cd with || exit is clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\ncd /tmp || exit 1\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_cd_no_check) found = true;
    }
    try std.testing.expect(!found);
}

test "JB1006 read without -r" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nread name\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_read_no_r) found = true;
    }
    try std.testing.expect(found);
}

test "JB1006 read -r is clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nread -r name\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_read_no_r) found = true;
    }
    try std.testing.expect(!found);
}

test "JB1007 local masks return" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nfoo() {\n  local x=$(cmd)\n}\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_local_mask_return) found = true;
    }
    try std.testing.expect(found);
}

test "JB1007 local without cmd sub is clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nfoo() {\n  local x=hello\n}\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_local_mask_return) found = true;
    }
    try std.testing.expect(!found);
}

test "JB1001 quoted positional local assignment is clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\nfoo() {\n  local known_hosts_file=\"$1\"\n}\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_unquoted_var) found = true;
    }
    try std.testing.expect(!found);
}

test "JB1008 double eq in test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\n[ \"$x\" == \"y\" ]\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_test_double_eq) found = true;
    }
    try std.testing.expect(found);
}

test "JB1008 fix replaces == with =" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\n[ \"$x\" == \"y\" ]\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, false);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "= \"y\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.output, "== \"y\"") == null);
}

test "JB1009 dollar question in test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\ncmd\nif [ $? -eq 0 ]; then echo ok; fi\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_dollar_question) found = true;
    }
    try std.testing.expect(found);
}

test "JB1010 -a in test" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\n[ -f foo -a -f bar ]\n";

    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_test_and_or) found = true;
    }
    try std.testing.expect(found);
}

test "JB1010 -a as file test is clean" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\n[ -a foo ]\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    var found = false;
    for (result.diagnostics) |d| {
        if (d.rule == .bash_test_and_or) found = true;
    }
    try std.testing.expect(!found);
}

test "clean bash no diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const source = "#!/bin/bash\necho \"hello\"\n";
    const result = fix(alloc, source, "test.sh", SkipSet{}, true);
    try std.testing.expectEqual(@as(usize, 0), result.diagnostics.len);
}
