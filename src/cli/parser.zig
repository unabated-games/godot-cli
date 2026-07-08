const std = @import("std");
const spec = @import("spec.zig");

pub const ParseError = spec.CliError;

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

    if (index < argv.len) {
        inv.positionals = argv[index..];
    }

    return inv;
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
            try inv.options.put(allocator, opt.long, value);
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
            try inv.options.put(allocator, opt.long, value);
            return;
        }
    }
    return error.UnknownOption;
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
        .string, .path => {
            const eq = std.mem.indexOfScalar(u8, arg, '=');
            if (eq) |at| {
                return try allocator.dupe(u8, arg[at + 1 ..]);
            }
            index.* += 1;
            if (index.* >= argv.len) return error.MissingValue;
            return try allocator.dupe(u8, argv[index.*]);
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

    const inv = try parseArgv(allocator, &commands.root, &.{"ping", "--json"});
    defer {
        var mutable = inv;
        mutable.deinit(allocator);
    }

    try std.testing.expect(inv.global.json_output);
    try std.testing.expectEqual(@as(usize, 1), inv.path.len);
    try std.testing.expectEqualStrings("ping", inv.path[0]);
}
