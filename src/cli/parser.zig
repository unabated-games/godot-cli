const std = @import("std");
const spec = @import("spec.zig");
const error_details = @import("../godot/error_details.zig");
const help = @import("help.zig");

pub const ParseError = spec.CliError;

/// The command path in `argv`, for an error raised before an `Invocation`
/// exists to carry it. Names are static spec data, so the returned slice
/// outlives `buf` only as far as `buf` itself.
pub fn commandPathForError(
    root: *const spec.CommandSpec,
    argv: []const []const u8,
    buf: [][]const u8,
) []const []const u8 {
    var current: *const spec.CommandSpec = root;
    var depth: usize = 0;
    for (argv) |token| {
        if (std.mem.eql(u8, token, "--")) break;
        if (std.mem.startsWith(u8, token, "-")) continue;
        if (depth == buf.len) break;
        var found: ?*const spec.CommandSpec = null;
        for (current.children, 0..) |child, i| {
            if (std.mem.eql(u8, child.name, token)) {
                found = &current.children[i];
                break;
            }
        }
        const next = found orelse break;
        buf[depth] = next.name;
        depth += 1;
        current = next;
    }
    return buf[0..depth];
}

pub fn parseArgv(
    allocator: std.mem.Allocator,
    root: *const spec.CommandSpec,
    argv: []const []const u8,
) ParseError!spec.Invocation {
    var inv: spec.Invocation = .{};
    errdefer inv.deinit(allocator);

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (!std.mem.startsWith(u8, arg, "-")) break;

        const parsed = try parseGlobalOrRootOption(allocator, root, arg, argv, &index, &inv);
        switch (parsed) {
            .global => continue,
            .stop => break,
            .unknown => return error.UnknownOption,
        }
    }

    if (index >= argv.len) return inv;

    const command = try resolveCommand(allocator, root, argv[index..]);
    inv.path = command.path;
    index += command.consumed;

    const leaf = command.leaf;
    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            break;
        }
        if (!std.mem.startsWith(u8, arg, "-")) break;

        if (isGlobalFlag(arg)) {
            applyGlobalFlag(arg, &inv.global);
            continue;
        }

        try parseCommandOption(allocator, leaf, arg, argv, &index, &inv);
    }

    var positionals = std.ArrayList([]const u8).empty;
    errdefer positionals.deinit(allocator);

    while (index < argv.len) : (index += 1) {
        const arg = argv[index];
        if (std.mem.eql(u8, arg, "--")) {
            index += 1;
            while (index < argv.len) : (index += 1) {
                try positionals.append(allocator, argv[index]);
            }
            break;
        }
        if (std.mem.startsWith(u8, arg, "-")) {
            if (isGlobalFlag(arg)) {
                applyGlobalFlag(arg, &inv.global);
                continue;
            }
            try parseCommandOption(allocator, leaf, arg, argv, &index, &inv);
            continue;
        }
        try positionals.append(allocator, arg);
    }

    inv.positionals = try positionals.toOwnedSlice(allocator);

    // Enforced here rather than in each handler, which used to answer a
    // missing required flag with the bare word "Usage" and nothing else --
    // not the flag, not the usage text. Help and version are asked for
    // without the rest of a command line, so they are exempt.
    if (!inv.global.help and !inv.global.version) {
        for (leaf.options) |opt| {
            if (!opt.required or inv.options.get(opt.long) != null) continue;
            noteMissingOption(allocator, leaf, inv.path, opt.long);
            return error.Usage;
        }
    }

    return inv;
}

fn noteMissingOption(
    allocator: std.mem.Allocator,
    command: *const spec.CommandSpec,
    path: []const []const u8,
    missing: []const u8,
) void {
    var usage: std.ArrayList(u8) = .empty;
    help.appendUsageLine(&usage, allocator, command, path) catch return;

    var required: std.ArrayList(u8) = .empty;
    var count: usize = 0;
    for (command.options) |opt| {
        if (!opt.required) continue;
        required.appendSlice(allocator, if (count == 0) "--" else ", --") catch return;
        required.appendSlice(allocator, opt.long) catch return;
        count += 1;
    }

    const hint = std.fmt.allocPrint(
        allocator,
        "usage: {s}; this command requires {s}",
        .{ usage.items, required.items },
    ) catch return;
    const joined = std.mem.join(allocator, " ", path) catch return;
    error_details.record(.{ .command = joined, .field = missing, .hint = hint });
}

const GlobalParse = enum {
    global,
    stop,
    unknown,
};

fn parseGlobalOrRootOption(
    allocator: std.mem.Allocator,
    root: *const spec.CommandSpec,
    arg: []const u8,
    argv: []const []const u8,
    index: *usize,
    inv: *spec.Invocation,
) ParseError!GlobalParse {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
        inv.global.help = true;
        return .global;
    }
    if (std.mem.eql(u8, arg, "--version")) {
        inv.global.version = true;
        return .global;
    }
    if (std.mem.eql(u8, arg, "--json")) {
        inv.global.json_output = true;
        return .global;
    }
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) {
        inv.global.verbose = true;
        return .global;
    }
    if (std.mem.eql(u8, arg, "--request")) {
        return .stop;
    }
    if (std.mem.eql(u8, arg, "--request-file")) {
        return .stop;
    }
    if (std.mem.eql(u8, arg, "--request-stdin")) {
        return .stop;
    }

    if (try takeRootOption(allocator, root, arg, argv, index, inv)) {
        return .global;
    }

    return .unknown;
}

fn takeRootOption(
    allocator: std.mem.Allocator,
    root: *const spec.CommandSpec,
    arg: []const u8,
    argv: []const []const u8,
    index: *usize,
    inv: *spec.Invocation,
) ParseError!bool {
    for (root.options) |opt| {
        if (matchesOption(opt, arg)) {
            const value = try readOptionValue(allocator, opt, arg, argv, index);
            if (try inv.options.fetchPut(allocator, opt.long, value)) |old| allocator.free(old.value);
            return true;
        }
    }
    return false;
}

fn parseCommandOption(
    allocator: std.mem.Allocator,
    command: *const spec.CommandSpec,
    arg: []const u8,
    argv: []const []const u8,
    index: *usize,
    inv: *spec.Invocation,
) ParseError!void {
    for (command.options) |opt| {
        if (matchesOption(opt, arg)) {
            const value = try readOptionValue(allocator, opt, arg, argv, index);
            if (opt.repeatable) {
                if (inv.options.get(opt.long)) |existing| {
                    const joined = try std.mem.join(allocator, &.{spec.repeat_separator}, &.{ existing, value });
                    allocator.free(value);
                    if (try inv.options.fetchPut(allocator, opt.long, joined)) |old| allocator.free(old.value);
                    return;
                }
            }
            if (try inv.options.fetchPut(allocator, opt.long, value)) |old| allocator.free(old.value);
            return;
        }
    }
    // A bare "unknown option" is close to useless in a piped --json workflow:
    // it names neither the flag nor the command, so a mistyped or
    // wrong-command flag reads as a generic failure and is easy to scroll
    // past. Naming both, and the nearest accepted spelling, is what makes it
    // a correction rather than a hunt.
    noteUnknownOption(allocator, command, inv.path, arg);
    return error.UnknownOption;
}

/// The accepted options, and the nearest one to what was typed.
fn noteUnknownOption(
    allocator: std.mem.Allocator,
    command: *const spec.CommandSpec,
    path: []const []const u8,
    arg: []const u8,
) void {
    const typed = std.mem.trimStart(u8, arg, "-");
    const cut = std.mem.indexOfScalar(u8, typed, '=') orelse typed.len;
    const bare = typed[0..cut];

    var closest: ?[]const u8 = null;
    var best: usize = std.math.maxInt(usize);
    for (command.options) |opt| {
        const distance = editDistance(bare, opt.long);
        if (distance < best) {
            best = distance;
            closest = opt.long;
        }
    }

    // A parent command has no options of its own, so listing them produced
    // "this command takes " and stopped. The real mistake there is options
    // meant for a subcommand, so name those instead.
    if (command.options.len == 0) {
        var subcommands: std.ArrayList(u8) = .empty;
        for (command.children, 0..) |child, i| {
            subcommands.appendSlice(allocator, if (i == 0) "" else ", ") catch return;
            subcommands.appendSlice(allocator, child.name) catch return;
        }
        const hint = if (command.children.len != 0)
            std.fmt.allocPrint(allocator, "this command takes no options of its own; its subcommands do: {s}", .{subcommands.items}) catch return
        else
            allocator.dupe(u8, "this command takes no options") catch return;
        const joined_parent = std.mem.join(allocator, " ", path) catch return;
        error_details.record(.{ .command = joined_parent, .field = bare, .value = arg, .hint = hint });
        return;
    }

    var accepted: std.ArrayList(u8) = .empty;
    for (command.options, 0..) |opt, i| {
        accepted.appendSlice(allocator, if (i == 0) "--" else ", --") catch return;
        accepted.appendSlice(allocator, opt.long) catch return;
    }

    // Half the shorter name is a loose enough bar to catch a transposition or
    // a dropped letter, and tight enough that an unrelated flag stays
    // unsuggested -- `--to` against `--parent` gets the accepted list, not a
    // confident wrong guess.
    const suggest = closest != null and best <= @max(bare.len, 2) / 2;
    const hint = if (suggest)
        std.fmt.allocPrint(allocator, "did you mean --{s}? this command takes {s}", .{ closest.?, accepted.items }) catch return
    else
        std.fmt.allocPrint(allocator, "this command takes {s}", .{accepted.items}) catch return;

    const joined = std.mem.join(allocator, " ", path) catch return;
    error_details.record(.{ .command = joined, .field = bare, .value = arg, .hint = hint });
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    // Bounded so the row fits a fixed buffer; option names are short, and a
    // pathological argument should not cost more than a wrong answer.
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);

    var previous: [65]usize = undefined;
    var current: [65]usize = undefined;
    for (0..b.len + 1) |i| previous[i] = i;

    for (a, 0..) |ca, i| {
        current[0] = i + 1;
        for (b, 0..) |cb, j| {
            const substitute = previous[j] + @intFromBool(ca != cb);
            const insert = current[j] + 1;
            const delete = previous[j + 1] + 1;
            current[j + 1] = @min(substitute, @min(insert, delete));
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

fn isGlobalFlag(arg: []const u8) bool {
    return std.mem.eql(u8, arg, "-h") or
        std.mem.eql(u8, arg, "--help") or
        std.mem.eql(u8, arg, "--version") or
        std.mem.eql(u8, arg, "--json") or
        std.mem.eql(u8, arg, "-v") or
        std.mem.eql(u8, arg, "--verbose");
}

fn applyGlobalFlag(arg: []const u8, global: *spec.GlobalOptions) void {
    if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) global.help = true;
    if (std.mem.eql(u8, arg, "--version")) global.version = true;
    if (std.mem.eql(u8, arg, "--json")) global.json_output = true;
    if (std.mem.eql(u8, arg, "-v") or std.mem.eql(u8, arg, "--verbose")) global.verbose = true;
}

fn matchesOption(opt: spec.OptionSpec, arg: []const u8) bool {
    if (arg.len >= 2 + opt.long.len and std.mem.eql(u8, arg[0..2], "--")) {
        if (arg.len == 2 + opt.long.len and std.mem.eql(u8, arg[2..][0..opt.long.len], opt.long)) return true;
        if (arg.len > 2 + opt.long.len and std.mem.eql(u8, arg[2..][0..opt.long.len], opt.long) and arg[2 + opt.long.len] == '=') return true;
    }

    if (opt.short) |short_char| {
        if (arg.len == 2 and arg[0] == '-' and arg[1] == short_char) return true;
    }
    return false;
}

fn readOptionValue(
    allocator: std.mem.Allocator,
    opt: spec.OptionSpec,
    arg: []const u8,
    argv: []const []const u8,
    index: *usize,
) ParseError![]const u8 {
    switch (opt.kind) {
        .flag => return try allocator.dupe(u8, ""),
        .string, .path, .integer => {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            const raw = if (eq) |at| arg[at + 1 ..] else blk: {
                index.* += 1;
                if (index.* >= argv.len) return error.MissingValue;
                break :blk argv[index.*];
            };
            if (opt.kind == .integer) {
                _ = std.fmt.parseInt(i64, raw, 10) catch return error.InvalidValue;
            }
            return try allocator.dupe(u8, raw);
        },
    }
}

const ResolvedCommand = struct {
    path: []const []const u8,
    leaf: *const spec.CommandSpec,
    consumed: usize,
};

fn resolveCommand(
    allocator: std.mem.Allocator,
    root: *const spec.CommandSpec,
    argv: []const []const u8,
) ParseError!ResolvedCommand {
    var current: *const spec.CommandSpec = root;
    var consumed: usize = 0;
    var depth: usize = 0;
    var path = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(path);

    while (consumed < argv.len) : (consumed += 1) {
        const token = argv[consumed];
        if (std.mem.startsWith(u8, token, "-")) break;

        var found: ?*const spec.CommandSpec = null;
        for (current.children, 0..) |child, child_index| {
            if (std.mem.eql(u8, child.name, token)) {
                found = &current.children[child_index];
                break;
            }
        }
        const next = found orelse break;

        path = try allocator.realloc(path, depth + 1);
        path[depth] = next.name;
        depth += 1;
        current = next;
    }

    if (depth == 0) {
        allocator.free(path);
        return error.Usage;
    }

    return .{
        .path = path,
        .leaf = current,
        .consumed = consumed,
    };
}

test "parse ping command" {
    const commands = @import("../commands.zig");
    const allocator = std.testing.allocator;

    const inv = try parseArgv(allocator, &commands.root, &.{ "ping", "--json" });
    defer {
        var mutable = inv;
        mutable.deinit(allocator);
    }

    try std.testing.expect(inv.global.json_output);
    try std.testing.expectEqual(@as(usize, 1), inv.path.len);
    try std.testing.expectEqualStrings("ping", inv.path[0]);
}

test "parse options after positionals" {
    const commands = @import("../commands.zig");
    const allocator = std.testing.allocator;

    const inv = try parseArgv(allocator, &commands.root, &.{
        "scene", "validate", "main.tscn", "--json", "--project-root", ".",
    });
    defer {
        var mutable = inv;
        mutable.deinit(allocator);
    }

    try std.testing.expect(inv.global.json_output);
    try std.testing.expectEqual(@as(usize, 1), inv.positionals.len);
    try std.testing.expectEqualStrings("main.tscn", inv.positionals[0]);
    try std.testing.expectEqualStrings(".", inv.getOption("project-root").?);
}

test "every documented global option is recognised" {
    const commands = @import("../commands.zig");
    const allocator = std.testing.allocator;

    for (spec.global_options) |opt| {
        const arg = try std.fmt.allocPrint(allocator, "--{s}", .{opt.long});
        defer allocator.free(arg);

        var inv: spec.Invocation = .{};
        defer inv.deinit(allocator);

        var index: usize = 0;
        const outcome = try parseGlobalOrRootOption(allocator, &commands.root, arg, &.{arg}, &index, &inv);
        try std.testing.expect(outcome != .unknown);
    }
}

test "repeatable options accumulate in argv order" {
    const commands = @import("../commands.zig");
    const allocator = std.testing.allocator;
    var inv = try parseArgv(allocator, &commands.root, &.{
        "scene",      "node",         "add",     "a.tscn", "--parent",   "/root/Main",    "--name",  "N",   "--type", "Control",
        "--property", "anchor_right", "--value", "1.0",    "--property", "anchor_bottom", "--value", "1.0",
    });
    defer inv.deinit(allocator);
    const names = try inv.getOptionAll(allocator, "property");
    defer allocator.free(names);
    const values = try inv.getOptionAll(allocator, "value");
    defer allocator.free(values);
    try std.testing.expectEqual(@as(usize, 2), names.len);
    try std.testing.expectEqualStrings("anchor_bottom", names[1]);
    try std.testing.expectEqualStrings("1.0", values[1]);
}

test "an unknown option names itself, the command, and what was accepted" {
    const commands = @import("../commands.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A silent "unknown option" cost another session a scene: the reparent
    // was rejected, unnoticed, and a recursive remove ran next.
    error_details.clear();
    try std.testing.expectError(error.UnknownOption, parseArgv(arena, &commands.root, &.{
        "scene", "node", "reparent", "a.tscn", "/root/Main/Kid", "--to", "/root/Main/Field",
    }));
    const details = (try error_details.takeJson(arena)).?;
    try std.testing.expectEqualStrings("scene node reparent", details.get("command").?.string);
    try std.testing.expectEqualStrings("to", details.get("field").?.string);
    try std.testing.expectEqualStrings("--to", details.get("value").?.string);
    // --to is nowhere near --parent, so the accepted set is the answer rather
    // than a confident wrong guess.
    const hint = details.get("hint").?.string;
    try std.testing.expect(std.mem.indexOf(u8, hint, "--parent") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "did you mean") == null);

    error_details.clear();
    try std.testing.expectError(error.UnknownOption, parseArgv(arena, &commands.root, &.{
        "scene", "node", "reparent", "a.tscn", "/root/Main/Kid", "--parnet", "/root/Main/Field",
    }));
    const typo = (try error_details.takeJson(arena)).?;
    try std.testing.expect(std.mem.indexOf(u8, typo.get("hint").?.string, "did you mean --parent?") != null);
    error_details.clear();
}

test "a missing required option names itself and the usage line" {
    const commands = @import("../commands.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The handler used to answer this with the bare word "Usage".
    error_details.clear();
    try std.testing.expectError(error.Usage, parseArgv(arena, &commands.root, &.{
        "scene", "node", "reparent", "a.tscn", "/root/Main/Kid",
    }));
    const details = (try error_details.takeJson(arena)).?;
    try std.testing.expectEqualStrings("parent", details.get("field").?.string);
    try std.testing.expect(std.mem.indexOf(u8, details.get("hint").?.string, "godot-cli scene node reparent") != null);

    // --help is asked for without the rest of a command line.
    error_details.clear();
    var inv = try parseArgv(arena, &commands.root, &.{ "scene", "node", "reparent", "--help" });
    defer inv.deinit(arena);
    error_details.clear();
}

test "the command path survives an error that happens before the invocation does" {
    const commands = @import("../commands.zig");
    var buf: [8][]const u8 = undefined;
    const path = commandPathForError(&commands.root, &.{ "scene", "node", "reparent", "a.tscn", "--to", "x" }, &buf);
    try std.testing.expectEqual(@as(usize, 3), path.len);
    try std.testing.expectEqualStrings("reparent", path[2]);

    // Leading global flags come before the command and must not stop the walk.
    const with_flags = commandPathForError(&commands.root, &.{ "--json", "scene", "validate", "a.tscn" }, &buf);
    try std.testing.expectEqual(@as(usize, 2), with_flags.len);
    try std.testing.expectEqualStrings("validate", with_flags[1]);
}

test "a parent command's unknown option names its subcommands, not an empty list" {
    const commands = @import("../commands.zig");
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // `uid cache` has subcommands and no options of its own, so listing its
    // options produced "this command takes " and stopped there.
    error_details.clear();
    try std.testing.expectError(error.UnknownOption, parseArgv(arena, &commands.root, &.{
        "uid", "cache", "--project-root", ".",
    }));
    const details = (try error_details.takeJson(arena)).?;
    const hint = details.get("hint").?.string;
    try std.testing.expect(std.mem.indexOf(u8, hint, "no options of its own") != null);
    try std.testing.expect(std.mem.indexOf(u8, hint, "list") != null);
    try std.testing.expect(std.mem.endsWith(u8, hint, " ") == false);
    error_details.clear();
}
