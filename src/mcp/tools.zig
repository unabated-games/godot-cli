//! MCP tools derived from the CommandSpec tree.
//!
//! Every runnable command except the ones that describe the CLI itself becomes
//! one tool, named by joining its path with underscores (`scene node add` is
//! `scene_node_add`, the same names `docs/mcp_tools.json` uses). The input
//! schema comes from the command's options and positionals, and a call is
//! turned back into an argv and run in-process through `App.invoke`, so a
//! tool call and a shell invocation cannot behave differently.

const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const emit = @import("../output/emit.zig");
const builtin = @import("builtin");

/// Commands that describe the CLI rather than edit a Godot file. Kept in step
/// with the exclusion set in `tools/check_mcp_tools.sh`.
pub const excluded = [_][]const u8{ "help", "ping", "completions", "man", "reference", "mcp" };

/// Set from `godot-cli mcp --all-options`; otherwise advanced options are
/// left out of the schemas and rejected as unknown.
pub var include_advanced: bool = false;

pub const Tool = struct {
    name: []const u8,
    path: []const []const u8,
    command: *const spec.CommandSpec,
};

pub fn isExcluded(first_segment: []const u8) bool {
    for (excluded) |name| if (std.mem.eql(u8, name, first_segment)) return true;
    return false;
}

/// Walk the tree in declaration order, which is deterministic, so clients that
/// cache the tool list see the same order every time.
pub fn collect(allocator: std.mem.Allocator, root: *const spec.CommandSpec) ![]Tool {
    var out: std.ArrayList(Tool) = .empty;
    var path: std.ArrayList([]const u8) = .empty;
    defer path.deinit(allocator);
    try walk(allocator, root, &path, &out);
    return out.toOwnedSlice(allocator);
}

fn walk(
    allocator: std.mem.Allocator,
    parent: *const spec.CommandSpec,
    path: *std.ArrayList([]const u8),
    out: *std.ArrayList(Tool),
) !void {
    for (parent.children, 0..) |_, index| {
        const child = &parent.children[index];
        try path.append(allocator, child.name);
        defer _ = path.pop();
        if (child.handler != null and !isExcluded(path.items[0])) {
            const segments = try allocator.dupe([]const u8, path.items);
            try out.append(allocator, .{
                .name = try std.mem.join(allocator, "_", segments),
                .path = segments,
                .command = child,
            });
        }
        try walk(allocator, child, path, out);
    }
}

pub fn find(tools: []const Tool, name: []const u8) ?*const Tool {
    for (tools) |*tool| if (std.mem.eql(u8, tool.name, name)) return tool;
    return null;
}

pub fn declaresProjectRoot(command: *const spec.CommandSpec) bool {
    for (command.options) |opt| if (std.mem.eql(u8, opt.long, "project-root")) return true;
    return false;
}

/// Commands whose last segment only reads. Advisory; clients treat it as a hint.
fn isReadOnly(tool: *const Tool) bool {
    const last = tool.path[tool.path.len - 1];
    const read_only = [_][]const u8{ "list", "get", "show", "inspect", "validate", "validate-batch", "diff", "refs", "plan", "search", "lookup", "encode", "decode", "create-for-path", "generate", "scan", "compare-godot" };
    for (read_only) |name| if (std.mem.eql(u8, name, last)) return true;
    return false;
}

/// The `tools/list` entry for one tool. In pinned mode `project-root` is
/// injected by the server and left out of the schema.
pub fn toolJson(allocator: std.mem.Allocator, tool: *const Tool, pinned: bool) !std.json.Value {
    var properties: std.json.ObjectMap = .{};
    var required: std.json.Array = .init(allocator);

    for (tool.command.positionals) |arg| {
        var prop: std.json.ObjectMap = .{};
        if (arg.variadic) {
            try prop.put(allocator, "type", .{ .string = "array" });
            var items: std.json.ObjectMap = .{};
            try items.put(allocator, "type", .{ .string = "string" });
            try prop.put(allocator, "items", .{ .object = items });
        } else {
            try prop.put(allocator, "type", .{ .string = "string" });
        }
        try prop.put(allocator, "description", .{ .string = try describe(allocator, arg.description, arg.kind, pinned) });
        try properties.put(allocator, arg.name, .{ .object = prop });
        if (arg.required) try required.append(.{ .string = arg.name });
    }

    for (tool.command.options) |opt| {
        if (pinned and std.mem.eql(u8, opt.long, "project-root")) continue;
        if (opt.advanced and !include_advanced) continue;
        var prop: std.json.ObjectMap = .{};
        if (opt.repeatable) {
            try prop.put(allocator, "type", .{ .string = "array" });
            var items: std.json.ObjectMap = .{};
            try items.put(allocator, "type", .{ .string = "string" });
            try prop.put(allocator, "items", .{ .object = items });
        } else if (acceptsJson(opt)) {
            // The CLI takes the document as text; an agent may send the object.
            var types: std.json.Array = .init(allocator);
            try types.append(.{ .string = "object" });
            try types.append(.{ .string = "string" });
            try prop.put(allocator, "type", .{ .array = types });
        } else {
            try prop.put(allocator, "type", .{ .string = switch (opt.kind) {
                .flag => "boolean",
                .integer => "integer",
                .string, .path => "string",
            } });
        }
        try prop.put(allocator, "description", .{ .string = try describe(allocator, opt.description, opt.kind, pinned) });
        if (opt.default_value) |default_value| {
            if (opt.kind == .integer) {
                if (std.fmt.parseInt(i64, default_value, 10)) |n| try prop.put(allocator, "default", .{ .integer = n }) else |_| try prop.put(allocator, "default", .{ .string = default_value });
            } else {
                try prop.put(allocator, "default", .{ .string = default_value });
            }
        }
        try properties.put(allocator, opt.long, .{ .object = prop });
        if (opt.required) try required.append(.{ .string = opt.long });
    }

    var schema: std.json.ObjectMap = .{};
    try schema.put(allocator, "type", .{ .string = "object" });
    try schema.put(allocator, "properties", .{ .object = properties });
    try schema.put(allocator, "required", .{ .array = required });
    try schema.put(allocator, "additionalProperties", .{ .bool = false });

    var annotations: std.json.ObjectMap = .{};
    try annotations.put(allocator, "title", .{ .string = try std.mem.join(allocator, " ", tool.path) });
    try annotations.put(allocator, "readOnlyHint", .{ .bool = isReadOnly(tool) });
    try annotations.put(allocator, "openWorldHint", .{ .bool = false });

    var row: std.json.ObjectMap = .{};
    try row.put(allocator, "name", .{ .string = tool.name });
    try row.put(allocator, "title", .{ .string = try std.mem.join(allocator, " ", tool.path) });
    try row.put(allocator, "description", .{ .string = try description(allocator, tool) });
    try row.put(allocator, "inputSchema", .{ .object = schema });
    try row.put(allocator, "annotations", .{ .object = annotations });
    return .{ .object = row };
}

/// Options that carry a JSON document: `--intent-json`, `--patch-json`,
/// `--json-body`, `--properties`. An object argument is serialised for them.
pub fn acceptsJson(opt: spec.OptionSpec) bool {
    if (opt.kind == .flag) return false;
    return std.mem.endsWith(u8, opt.long, "-json") or std.mem.eql(u8, opt.long, "json-body") or std.mem.eql(u8, opt.long, "properties");
}

fn describe(allocator: std.mem.Allocator, text: []const u8, kind: spec.ValueKind, pinned: bool) ![]const u8 {
    if (kind != .path) return text;
    return std.fmt.allocPrint(allocator, "{s}. A path, relative to {s}", .{
        text,
        if (pinned) "the project root" else "the server's working directory",
    });
}

fn description(allocator: std.mem.Allocator, tool: *const Tool) ![]const u8 {
    if (tool.command.description) |long| {
        return std.fmt.allocPrint(allocator, "{s}\n\n{s}", .{ tool.command.summary, long });
    }
    return tool.command.summary;
}

pub const ArgvOutcome = union(enum) {
    argv: []const []const u8,
    /// The arguments did not match the schema; the message names the field.
    invalid: []const u8,
};

pub const Confinement = struct {
    /// Absolute project root when the server was started with --project-root.
    root: ?[]const u8 = null,
};

/// Build the argv for a call, checking the arguments against the schema first
/// so a wrong type or unknown field is a protocol error rather than a usage
/// failure from the parser. In pinned mode every path argument must resolve
/// inside the project root.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    tool: *const Tool,
    arguments: ?std.json.ObjectMap,
    confinement: Confinement,
) !ArgvOutcome {
    const args: std.json.ObjectMap = arguments orelse .{};
    const pinned = confinement.root != null;

    var it = args.iterator();
    while (it.next()) |entry| {
        if (!isKnownArgument(tool, entry.key_ptr.*, pinned)) {
            return .{ .invalid = try std.fmt.allocPrint(allocator, "unknown argument \"{s}\" for tool {s}", .{ entry.key_ptr.*, tool.name }) };
        }
    }

    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, tool.path);

    for (tool.command.options) |opt| {
        if (pinned and std.mem.eql(u8, opt.long, "project-root")) continue;
        if (opt.advanced and !include_advanced) continue;
        const value = args.get(opt.long) orelse continue;
        switch (opt.kind) {
            .flag => switch (value) {
                .bool => |enabled| if (enabled) try argv.append(allocator, try std.fmt.allocPrint(allocator, "--{s}", .{opt.long})),
                else => return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be a boolean", .{opt.long}) },
            },
            .string, .path, .integer => {
                if (opt.repeatable) {
                    if (value != .array) return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be an array of strings", .{opt.long}) };
                    for (value.array.items) |item| {
                        const text = scalarText(allocator, item) catch return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be an array of strings", .{opt.long}) };
                        try argv.append(allocator, try std.fmt.allocPrint(allocator, "--{s}={s}", .{ opt.long, text }));
                    }
                } else {
                    const text = if (acceptsJson(opt) and (value == .object or value == .array))
                        try jsonText(allocator, value)
                    else
                        scalarText(allocator, value) catch return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be a string", .{opt.long}) };
                    if (opt.kind == .path) {
                        if (try outsideRoot(allocator, confinement, text)) return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" resolves outside the project root: {s}", .{ opt.long, text }) };
                    }
                    try argv.append(allocator, try std.fmt.allocPrint(allocator, "--{s}={s}", .{ opt.long, text }));
                }
            },
        }
    }

    if (pinned and declaresProjectRoot(tool.command)) {
        try argv.append(allocator, "--project-root=.");
    }

    for (tool.command.positionals) |arg| {
        const value = args.get(arg.name) orelse {
            if (arg.required) return .{ .invalid = try std.fmt.allocPrint(allocator, "missing required argument \"{s}\"", .{arg.name}) };
            continue;
        };
        if (arg.variadic) {
            if (value != .array or value.array.items.len == 0) return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be a non-empty array of strings", .{arg.name}) };
            for (value.array.items) |item| {
                const text = scalarText(allocator, item) catch return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be an array of strings", .{arg.name}) };
                if (arg.kind == .path and try outsideRoot(allocator, confinement, text)) return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" resolves outside the project root: {s}", .{ arg.name, text }) };
                try argv.append(allocator, text);
            }
        } else {
            const text = scalarText(allocator, value) catch return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" must be a string", .{arg.name}) };
            if (arg.kind == .path and try outsideRoot(allocator, confinement, text)) return .{ .invalid = try std.fmt.allocPrint(allocator, "argument \"{s}\" resolves outside the project root: {s}", .{ arg.name, text }) };
            try argv.append(allocator, text);
        }
    }

    return .{ .argv = try argv.toOwnedSlice(allocator) };
}

fn isKnownArgument(tool: *const Tool, key: []const u8, pinned: bool) bool {
    for (tool.command.positionals) |arg| if (std.mem.eql(u8, arg.name, key)) return true;
    for (tool.command.options) |opt| {
        if (pinned and std.mem.eql(u8, opt.long, "project-root")) continue;
        if (opt.advanced and !include_advanced) continue;
        if (std.mem.eql(u8, opt.long, key)) return true;
    }
    return false;
}

fn jsonText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.written();
}

fn scalarText(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        .number_string => |s| s,
        else => error.NotScalar,
    };
}

/// True when a path argument escapes the pinned project root. Godot scheme
/// paths are strings the CLI resolves itself and are left alone.
pub fn outsideRoot(allocator: std.mem.Allocator, confinement: Confinement, value: []const u8) !bool {
    const root = confinement.root orelse return false;
    if (std.mem.startsWith(u8, value, "res://") or std.mem.startsWith(u8, value, "uid://")) return false;
    const resolved = try std.fs.path.resolve(allocator, &.{ root, value });
    if (std.mem.eql(u8, resolved, root)) return false;
    const with_sep = try std.fmt.allocPrint(allocator, "{s}{c}", .{ root, std.fs.path.sep });
    return !std.mem.startsWith(u8, resolved, with_sep);
}

pub const CallResult = struct {
    /// The `--json` envelope, exactly as the CLI would print it.
    envelope: []const u8,
    is_error: bool,
};

/// Run one tool call in-process and return the envelope. Every failure path,
/// parse errors included, produces the same failure envelope the CLI prints.
pub fn call(allocator: std.mem.Allocator, app: *const app_mod.App, tool: *const Tool, argv: []const []const u8) !CallResult {
    var buffer: std.Io.Writer.Allocating = .init(allocator);
    const result = app.invoke(argv, true) catch |err| {
        const failure = failureFor(allocator, err);
        try emit.writeFailureEnvelope(&buffer.writer, tool.path, failure);
        return .{ .envelope = buffer.written(), .is_error = true };
    };
    // The same Debug-build guard the CLI runs: a result carrying invalid
    // UTF-8 is freed memory, and the smoke test should fail on it.
    if (builtin.mode == .Debug) {
        if (emit.firstInvalidString(result.data) orelse emit.firstInvalidStringIn(result.messages)) |bad| {
            var details: std.json.ObjectMap = .{};
            try details.put(allocator, "at", .{ .string = bad });
            try emit.writeFailureEnvelope(&buffer.writer, tool.path, .{
                .kind = "internal_invalid_output",
                .message = "result contained invalid UTF-8; this is a godot-cli bug",
                .details = .{ .object = details },
            });
            return .{ .envelope = buffer.written(), .is_error = true };
        }
    }
    try emit.writeSuccessEnvelope(&buffer.writer, tool.path, result);
    const failed = if (result.exit_code) |code| code != .success else false;
    return .{ .envelope = buffer.written(), .is_error = failed };
}

fn failureFor(allocator: std.mem.Allocator, err: anyerror) emit.Failure {
    return switch (err) {
        error.Usage, error.UnknownCommand, error.UnknownOption, error.MissingValue, error.InvalidValue, error.JsonInput => |e| emit.failureFromError(e),
        else => app_mod.failureFromHandlerError(allocator, err),
    };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const commands = @import("../commands.zig");

test "every runnable command outside the exclusion set is a tool with a valid name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = try collect(arena, &commands.root);
    try std.testing.expect(tools.len >= 80);

    for (tools, 0..) |tool, index| {
        try std.testing.expect(tool.name.len >= 1 and tool.name.len <= 128);
        for (tool.name) |c| try std.testing.expect(std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.');
        for (excluded) |name| try std.testing.expect(!std.mem.eql(u8, tool.name, name));
        for (tools[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, tool.name, other.name));

        // Positional and option names share one property namespace.
        for (tool.command.positionals) |arg| {
            for (tool.command.options) |opt| try std.testing.expect(!std.mem.eql(u8, arg.name, opt.long));
        }

        const json = try toolJson(arena, &tool, false);
        const schema = json.object.get("inputSchema").?.object;
        try std.testing.expectEqualStrings("object", schema.get("type").?.string);
        const properties = schema.get("properties").?.object;
        for (tool.command.options) |opt| try std.testing.expect(properties.contains(opt.long) or opt.advanced);
        for (tool.command.positionals) |arg| try std.testing.expect(properties.contains(arg.name));
    }
}

test "argv is built in path, option, project root, positional order" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = try collect(arena, &commands.root);
    const tool = find(tools, "scene_node_add").?;

    var args: std.json.ObjectMap = .{};
    try args.put(arena, "file", .{ .string = "scenes/main.tscn" });
    try args.put(arena, "parent", .{ .string = "/root/Main" });
    try args.put(arena, "name", .{ .string = "Player" });
    try args.put(arena, "type", .{ .string = "Node2D" });
    try args.put(arena, "dry-run", .{ .bool = true });
    try args.put(arena, "unique-name", .{ .bool = false });
    var props: std.json.Array = .init(arena);
    try props.append(.{ .string = "position" });
    try props.append(.{ .string = "modulate" });
    try args.put(arena, "property", .{ .array = props });
    var values: std.json.Array = .init(arena);
    try values.append(.{ .string = "Vector2(1, 2)" });
    try values.append(.{ .string = "Color(1, 1, 1, 1)" });
    try args.put(arena, "value", .{ .array = values });

    const outcome = try buildArgv(arena, tool, args, .{ .root = "/tmp/project" });
    const argv = outcome.argv;
    try std.testing.expectEqualStrings("scene", argv[0]);
    try std.testing.expectEqualStrings("node", argv[1]);
    try std.testing.expectEqualStrings("add", argv[2]);
    try std.testing.expectEqualStrings("scenes/main.tscn", argv[argv.len - 1]);

    var saw_root = false;
    var saw_unique = false;
    var saw_dry_run = false;
    var property_count: usize = 0;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "--project-root=.")) saw_root = true;
        if (std.mem.eql(u8, arg, "--unique-name")) saw_unique = true;
        if (std.mem.eql(u8, arg, "--dry-run")) saw_dry_run = true;
        if (std.mem.startsWith(u8, arg, "--property=")) property_count += 1;
    }
    try std.testing.expect(saw_root);
    try std.testing.expect(saw_dry_run);
    try std.testing.expect(!saw_unique);
    try std.testing.expectEqual(@as(usize, 2), property_count);
}

test "schema violations and escaped paths are reported by name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const tools = try collect(arena, &commands.root);
    const tool = find(tools, "scene_node_list").?;

    const no_file = try buildArgv(arena, tool, .{}, .{});
    try std.testing.expect(std.mem.indexOf(u8, no_file.invalid, "\"file\"") != null);

    var unknown: std.json.ObjectMap = .{};
    try unknown.put(arena, "file", .{ .string = "a.tscn" });
    try unknown.put(arena, "bogus", .{ .string = "x" });
    const bad_key = try buildArgv(arena, tool, unknown, .{});
    try std.testing.expect(std.mem.indexOf(u8, bad_key.invalid, "\"bogus\"") != null);

    var wrong_type: std.json.ObjectMap = .{};
    try wrong_type.put(arena, "file", .{ .bool = true });
    const bad_type = try buildArgv(arena, tool, wrong_type, .{});
    try std.testing.expect(std.mem.indexOf(u8, bad_type.invalid, "\"file\"") != null);

    var escaped: std.json.ObjectMap = .{};
    try escaped.put(arena, "file", .{ .string = "../../outside.tscn" });
    const outside = try buildArgv(arena, tool, escaped, .{ .root = "/tmp/project" });
    try std.testing.expect(std.mem.indexOf(u8, outside.invalid, "outside the project root") != null);

    var inside: std.json.ObjectMap = .{};
    try inside.put(arena, "file", .{ .string = "scenes/../main.tscn" });
    const ok = try buildArgv(arena, tool, inside, .{ .root = "/tmp/project" });
    try std.testing.expect(ok == .argv);

    // In pinned mode project-root is the server's to set, not the caller's.
    var pinned_root: std.json.ObjectMap = .{};
    try pinned_root.put(arena, "file", .{ .string = "main.tscn" });
    try pinned_root.put(arena, "project-root", .{ .string = "/elsewhere" });
    const rejected = try buildArgv(arena, tool, pinned_root, .{ .root = "/tmp/project" });
    try std.testing.expect(rejected == .invalid);
}
