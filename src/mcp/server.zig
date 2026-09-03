//! `godot-cli mcp`: a Model Context Protocol server over stdio.
//!
//! One long-lived process reads newline-delimited JSON-RPC 2.0 from stdin and
//! writes one response line per request to stdout. Nothing else is written to
//! stdout; diagnostics go to stderr, which the transport permits. The process
//! exits when stdin closes.
//!
//! The server is dual-era. A client that opens with `initialize` (protocol
//! revisions up to 2025-11-25) gets the legacy handshake; a client that sends
//! `server/discover` or carries the 2026-07-28 `_meta` fields is served
//! statelessly. Both eras share every other method, so the extra fields the
//! newer revision requires (`resultType`, `ttlMs`, `cacheScope`, the serverInfo
//! `_meta`) are emitted unconditionally; older clients ignore unknown fields.
//!
//! Each request runs in its own arena. Handlers run in-process through
//! `App.invoke`, the path `batch` already uses, and the error-detail side
//! channel is drained after every call so nothing leaks between requests.

const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const error_details = @import("../godot/error_details.zig");
const version = @import("../version.zig");
const tools = @import("tools.zig");
const resources = @import("resources.zig");
const prompts = @import("prompts.zig");
const scene_plan = @import("../godot/scene_plan.zig");

pub const Options = struct {
    /// Change into this directory, inject `--project-root .` into every call
    /// that accepts it, and refuse path arguments that resolve outside it.
    project_root: ?[]const u8 = null,
    /// Expose the save-preparation and id-session plumbing options too.
    include_advanced: bool = false,
};

pub const modern_versions = [_][]const u8{ "2026-07-28", "2025-11-25" };
pub const legacy_versions = [_][]const u8{ "2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25" };
const latest_legacy = "2025-11-25";

const instructions =
    \\godot-cli edits Godot 4 scene (.tscn), resource (.tres), and project.godot files the way the editor writes them.
    \\Read the resource godot-cli://docs/quickstart before the first edit; use the godot-scene-session prompt to start a session.
    \\Every tool returns the CLI's JSON envelope (ok, data, messages, failure); a failure's details name the field or value to fix.
    \\Discover with scene_node_list and catalog_list before editing, validate with scene_validate after every edit.
    \\The docs describe a --project-root option; over MCP there is none. When the server was started with --project-root it is bound to that project, adds the option to every call, and refuses paths outside it; project_show reports the absolute root. Otherwise paths resolve against the server's working directory.
;

const catalog_uri = "godot-cli://catalog";
const session_uri = "godot-cli://prompts/session";
const recipes_uri = "godot-cli://docs/recipes";

const State = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    root: *const spec.CommandSpec,
    environ: std.process.Environ,
    tool_list: []const tools.Tool,
    confinement: tools.Confinement,
    legacy: bool = false,

    fn pinned(self: *const State) bool {
        return self.confinement.root != null;
    }
};

pub fn serve(
    gpa: std.mem.Allocator,
    io: std.Io,
    root: *const spec.CommandSpec,
    environ: std.process.Environ,
    options: Options,
) !void {
    tools.include_advanced = options.include_advanced;
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    var confinement: tools.Confinement = .{};
    if (options.project_root) |dir_path| {
        const dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
        try std.process.setCurrentDir(io, dir);
        const len = try dir.realPath(io, &root_buf);
        confinement.root = root_buf[0..len];
    }

    var state = State{
        .gpa = gpa,
        .io = io,
        .root = root,
        .environ = environ,
        .tool_list = try tools.collect(gpa, root),
        .confinement = confinement,
    };

    var in_buf: [64 * 1024]u8 = undefined;
    var out_buf: [64 * 1024]u8 = undefined;
    var stdin_reader = std.Io.File.stdin().reader(io, &in_buf);
    const reader = &stdin_reader.interface;
    var stdout_writer = std.Io.File.Writer.initStreaming(std.Io.File.stdout(), io, &out_buf);
    const writer = &stdout_writer.interface;

    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();

    while (true) {
        _ = arena_state.reset(.retain_capacity);
        const arena = arena_state.allocator();

        // Lines are unbounded (a call can carry an inline intent), so stream
        // into an allocating writer rather than a fixed buffer.
        var line: std.Io.Writer.Allocating = .init(arena);
        _ = reader.streamDelimiterEnding(&line.writer, '\n') catch |err| switch (err) {
            error.ReadFailed => return,
            error.WriteFailed => return error.OutOfMemory,
        };
        const at_eof = if (reader.peekByte()) |_| false else |_| true;
        if (!at_eof) reader.toss(1);

        const text = std.mem.trim(u8, line.written(), " \t\r");
        if (text.len != 0) {
            try handleLine(&state, arena, text, writer);
            error_details.clear();
        }
        if (at_eof) return;
    }
}

const RpcError = struct {
    code: i64,
    message: []const u8,
    data: std.json.Value = .null,
};

const Outcome = union(enum) {
    result: std.json.Value,
    err: RpcError,
};

fn handleLine(state: *State, arena: std.mem.Allocator, text: []const u8, writer: *std.Io.Writer) !void {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch {
        return writeResponse(arena, writer, .null, .{ .err = .{ .code = -32700, .message = "parse error" } });
    };
    if (parsed != .object) {
        return writeResponse(arena, writer, .null, .{ .err = .{ .code = -32600, .message = "invalid request: expected a JSON-RPC object" } });
    }
    const message = parsed.object;
    const id: std.json.Value = message.get("id") orelse .null;
    const is_notification = message.get("id") == null;

    const method_value = message.get("method") orelse {
        if (is_notification) return;
        return writeResponse(arena, writer, id, .{ .err = .{ .code = -32600, .message = "invalid request: missing method" } });
    };
    if (method_value != .string) {
        if (is_notification) return;
        return writeResponse(arena, writer, id, .{ .err = .{ .code = -32600, .message = "invalid request: method must be a string" } });
    }
    const method = method_value.string;
    const params: ?std.json.ObjectMap = if (message.get("params")) |p| (if (p == .object) p.object else null) else null;

    // Notifications (initialized, cancelled, progress) get no response, and
    // none of them change what this server does.
    if (is_notification) return;

    if (unsupportedModernVersion(params)) |requested| {
        var data: std.json.ObjectMap = .{};
        var supported: std.json.Array = .init(arena);
        for (modern_versions) |v| try supported.append(.{ .string = v });
        try data.put(arena, "supported", .{ .array = supported });
        try data.put(arena, "requested", .{ .string = requested });
        return writeResponse(arena, writer, id, .{ .err = .{ .code = -32022, .message = "unsupported protocol version", .data = .{ .object = data } } });
    }

    const outcome = try dispatch(state, arena, method, params);
    try writeResponse(arena, writer, id, outcome);
}

/// A 2026-07-28 request names its protocol version in `_meta`; a version this
/// server does not speak is refused before dispatch.
fn unsupportedModernVersion(params: ?std.json.ObjectMap) ?[]const u8 {
    const p = params orelse return null;
    const meta = p.get("_meta") orelse return null;
    if (meta != .object) return null;
    const requested = meta.object.get("io.modelcontextprotocol/protocolVersion") orelse return null;
    if (requested != .string) return null;
    for (modern_versions) |v| if (std.mem.eql(u8, v, requested.string)) return null;
    return requested.string;
}

fn dispatch(state: *State, arena: std.mem.Allocator, method: []const u8, params: ?std.json.ObjectMap) !Outcome {
    if (std.mem.eql(u8, method, "initialize")) return initialize(state, arena, params);
    if (std.mem.eql(u8, method, "server/discover")) return discover(state, arena);
    if (std.mem.eql(u8, method, "ping")) return .{ .result = try baseResult(arena) };
    if (std.mem.eql(u8, method, "tools/list")) return listTools(state, arena);
    if (std.mem.eql(u8, method, "tools/call")) return callTool(state, arena, params);
    if (std.mem.eql(u8, method, "resources/list")) return listResources(state, arena);
    if (std.mem.eql(u8, method, "resources/templates/list")) {
        var result = try listResult(arena);
        try result.object.put(arena, "resourceTemplates", .{ .array = .init(arena) });
        return .{ .result = result };
    }
    if (std.mem.eql(u8, method, "resources/read")) return readResource(state, arena, params);
    if (std.mem.eql(u8, method, "prompts/list")) return listPrompts(arena);
    if (std.mem.eql(u8, method, "prompts/get")) return getPrompt(arena, params);
    if (std.mem.eql(u8, method, "logging/setLevel")) return .{ .result = try baseResult(arena) };
    return .{ .err = .{ .code = -32601, .message = try std.fmt.allocPrint(arena, "method not found: {s}", .{method}) } };
}

// ---------------------------------------------------------------------------
// Handshakes
// ---------------------------------------------------------------------------

fn serverInfo(arena: std.mem.Allocator) !std.json.Value {
    var info: std.json.ObjectMap = .{};
    try info.put(arena, "name", .{ .string = version.name });
    try info.put(arena, "title", .{ .string = "godot-cli" });
    try info.put(arena, "version", .{ .string = version.version });
    return .{ .object = info };
}

fn capabilities(arena: std.mem.Allocator) !std.json.Value {
    var caps: std.json.ObjectMap = .{};
    try caps.put(arena, "tools", .{ .object = .{} });
    try caps.put(arena, "resources", .{ .object = .{} });
    try caps.put(arena, "prompts", .{ .object = .{} });
    return .{ .object = caps };
}

/// Every result carries `resultType` and the serverInfo `_meta` the 2026
/// revision asks for. Legacy clients ignore both.
fn baseResult(arena: std.mem.Allocator) !std.json.Value {
    var meta: std.json.ObjectMap = .{};
    try meta.put(arena, "io.modelcontextprotocol/serverInfo", try serverInfo(arena));
    var result: std.json.ObjectMap = .{};
    try result.put(arena, "resultType", .{ .string = "complete" });
    try result.put(arena, "_meta", .{ .object = meta });
    return .{ .object = result };
}

/// List results additionally declare how long they may be cached. The tool,
/// resource, and prompt lists are fixed for the life of the binary.
fn listResult(arena: std.mem.Allocator) !std.json.Value {
    var result = try baseResult(arena);
    try result.object.put(arena, "ttlMs", .{ .integer = 3_600_000 });
    try result.object.put(arena, "cacheScope", .{ .string = "public" });
    return result;
}

fn initialize(state: *State, arena: std.mem.Allocator, params: ?std.json.ObjectMap) !Outcome {
    state.legacy = true;
    var protocol_version: []const u8 = latest_legacy;
    if (params) |p| {
        if (p.get("protocolVersion")) |requested| {
            if (requested == .string) {
                for (legacy_versions) |v| if (std.mem.eql(u8, v, requested.string)) {
                    protocol_version = v;
                };
            }
        }
    }
    var result = try baseResult(arena);
    try result.object.put(arena, "protocolVersion", .{ .string = protocol_version });
    try result.object.put(arena, "capabilities", try capabilities(arena));
    try result.object.put(arena, "serverInfo", try serverInfo(arena));
    try result.object.put(arena, "instructions", .{ .string = instructions });
    return .{ .result = result };
}

fn discover(state: *State, arena: std.mem.Allocator) !Outcome {
    _ = state;
    var supported: std.json.Array = .init(arena);
    for (modern_versions) |v| try supported.append(.{ .string = v });
    var result = try listResult(arena);
    try result.object.put(arena, "supportedVersions", .{ .array = supported });
    try result.object.put(arena, "capabilities", try capabilities(arena));
    try result.object.put(arena, "instructions", .{ .string = instructions });
    return .{ .result = result };
}

// ---------------------------------------------------------------------------
// Tools
// ---------------------------------------------------------------------------

fn listTools(state: *State, arena: std.mem.Allocator) !Outcome {
    var list: std.json.Array = .init(arena);
    for (state.tool_list) |*tool| try list.append(try tools.toolJson(arena, tool, state.pinned()));
    var result = try listResult(arena);
    try result.object.put(arena, "tools", .{ .array = list });
    return .{ .result = result };
}

fn callTool(state: *State, arena: std.mem.Allocator, params: ?std.json.ObjectMap) !Outcome {
    const p = params orelse return invalidParams(arena, "tools/call needs params with name and arguments");
    const name_value = p.get("name") orelse return invalidParams(arena, "tools/call needs a tool name");
    if (name_value != .string) return invalidParams(arena, "tool name must be a string");
    const tool = tools.find(state.tool_list, name_value.string) orelse {
        return invalidParams(arena, try std.fmt.allocPrint(arena, "unknown tool: {s}", .{name_value.string}));
    };
    var arguments: ?std.json.ObjectMap = null;
    if (p.get("arguments")) |a| {
        if (a != .object and a != .null) return invalidParams(arena, "arguments must be an object");
        if (a == .object) arguments = a.object;
    }

    const argv = switch (try tools.buildArgv(arena, tool, arguments, state.confinement)) {
        .argv => |argv| argv,
        .invalid => |message| return invalidParams(arena, message),
    };

    const app = app_mod.App{
        .root = state.root,
        .io = state.io,
        .allocator = arena,
        .environ = state.environ,
    };
    const outcome = try tools.call(arena, &app, tool, argv);
    return .{ .result = try callResult(arena, outcome.envelope, outcome.is_error) };
}

/// The envelope goes out twice: as the text block every client shows the
/// model, and parsed as `structuredContent` for clients that read it. Parsing
/// our own output guarantees the two cannot disagree.
fn callResult(arena: std.mem.Allocator, envelope: []const u8, is_error: bool) !std.json.Value {
    var text_block: std.json.ObjectMap = .{};
    try text_block.put(arena, "type", .{ .string = "text" });
    try text_block.put(arena, "text", .{ .string = envelope });
    var content: std.json.Array = .init(arena);
    try content.append(.{ .object = text_block });

    var result = try baseResult(arena);
    try result.object.put(arena, "content", .{ .array = content });
    if (std.json.parseFromSliceLeaky(std.json.Value, arena, envelope, .{})) |structured| {
        try result.object.put(arena, "structuredContent", structured);
    } else |_| {}
    try result.object.put(arena, "isError", .{ .bool = is_error });
    return result;
}

fn invalidParams(arena: std.mem.Allocator, message: []const u8) !Outcome {
    _ = arena;
    return .{ .err = .{ .code = -32602, .message = message } };
}

// ---------------------------------------------------------------------------
// Resources and prompts
// ---------------------------------------------------------------------------

fn listResources(state: *State, arena: std.mem.Allocator) !Outcome {
    var list: std.json.Array = .init(arena);
    for (&resources.docs) |*doc| {
        var row: std.json.ObjectMap = .{};
        try row.put(arena, "uri", .{ .string = doc.uri });
        try row.put(arena, "name", .{ .string = doc.name });
        try row.put(arena, "title", .{ .string = doc.title });
        try row.put(arena, "description", .{ .string = doc.description });
        try row.put(arena, "mimeType", .{ .string = doc.mime });
        try row.put(arena, "size", .{ .integer = @intCast(doc.text.len) });
        try list.append(.{ .object = row });
    }
    {
        var row: std.json.ObjectMap = .{};
        try row.put(arena, "uri", .{ .string = recipes_uri });
        try row.put(arena, "name", .{ .string = "recipes" });
        try row.put(arena, "title", .{ .string = "Intent recipes" });
        try row.put(arena, "description", .{ .string = "Every intent recipe with its required and optional fields, one line each. Read this instead of the full scene-authoring guide when writing an intent." });
        try row.put(arena, "mimeType", .{ .string = "text/markdown" });
        try list.append(.{ .object = row });
    }
    {
        // Many clients hide prompts; the session opener is a resource as well.
        var row: std.json.ObjectMap = .{};
        try row.put(arena, "uri", .{ .string = session_uri });
        try row.put(arena, "name", .{ .string = "session" });
        try row.put(arena, "title", .{ .string = "Session rules" });
        try row.put(arena, "description", .{ .string = "The rules and workflow the godot-scene-session prompt carries, for clients that do not surface prompts." });
        try row.put(arena, "mimeType", .{ .string = "text/markdown" });
        try row.put(arena, "size", .{ .integer = @intCast(prompts.rules.len) });
        try list.append(.{ .object = row });
    }
    if (state.pinned()) {
        var row: std.json.ObjectMap = .{};
        try row.put(arena, "uri", .{ .string = catalog_uri });
        try row.put(arena, "name", .{ .string = "catalog" });
        try row.put(arena, "title", .{ .string = "Project catalog" });
        try row.put(arena, "description", .{ .string = "The project's catalog entries, live: the components an agent should instance by id rather than rebuild." });
        try row.put(arena, "mimeType", .{ .string = "application/json" });
        try list.append(.{ .object = row });
    }
    var result = try listResult(arena);
    try result.object.put(arena, "resources", .{ .array = list });
    return .{ .result = result };
}

fn readResource(state: *State, arena: std.mem.Allocator, params: ?std.json.ObjectMap) !Outcome {
    const p = params orelse return invalidParams(arena, "resources/read needs a uri");
    const uri_value = p.get("uri") orelse return invalidParams(arena, "resources/read needs a uri");
    if (uri_value != .string) return invalidParams(arena, "uri must be a string");
    const uri = uri_value.string;

    var mime: []const u8 = undefined;
    var text: []const u8 = undefined;
    if (resources.find(uri)) |doc| {
        mime = doc.mime;
        text = doc.text;
    } else if (std.mem.eql(u8, uri, session_uri)) {
        mime = "text/markdown";
        text = prompts.rules;
    } else if (std.mem.eql(u8, uri, recipes_uri)) {
        mime = "text/markdown";
        text = try scene_plan.recipesReference(arena);
    } else if (state.pinned() and std.mem.eql(u8, uri, catalog_uri)) {
        const tool = tools.find(state.tool_list, "catalog_list").?;
        const argv = switch (try tools.buildArgv(arena, tool, null, state.confinement)) {
            .argv => |argv| argv,
            .invalid => |message| return invalidParams(arena, message),
        };
        const app = app_mod.App{ .root = state.root, .io = state.io, .allocator = arena, .environ = state.environ };
        const outcome = try tools.call(arena, &app, tool, argv);
        mime = "application/json";
        text = outcome.envelope;
    } else {
        var data: std.json.ObjectMap = .{};
        try data.put(arena, "uri", .{ .string = uri });
        return .{ .err = .{ .code = -32602, .message = try std.fmt.allocPrint(arena, "resource not found: {s}", .{uri}), .data = .{ .object = data } } };
    }

    var item: std.json.ObjectMap = .{};
    try item.put(arena, "uri", .{ .string = uri });
    try item.put(arena, "mimeType", .{ .string = mime });
    try item.put(arena, "text", .{ .string = text });
    var contents: std.json.Array = .init(arena);
    try contents.append(.{ .object = item });
    var result = try listResult(arena);
    try result.object.put(arena, "contents", .{ .array = contents });
    return .{ .result = result };
}

fn listPrompts(arena: std.mem.Allocator) !Outcome {
    var list: std.json.Array = .init(arena);
    try list.append(try prompts.listJson(arena));
    var result = try listResult(arena);
    try result.object.put(arena, "prompts", .{ .array = list });
    return .{ .result = result };
}

fn getPrompt(arena: std.mem.Allocator, params: ?std.json.ObjectMap) !Outcome {
    const p = params orelse return invalidParams(arena, "prompts/get needs a name");
    const name_value = p.get("name") orelse return invalidParams(arena, "prompts/get needs a name");
    if (name_value != .string or !std.mem.eql(u8, name_value.string, prompts.session_name)) {
        return invalidParams(arena, "unknown prompt");
    }
    var arguments: ?std.json.ObjectMap = null;
    if (p.get("arguments")) |a| if (a == .object) {
        arguments = a.object;
    };
    const prompt = try prompts.getJson(arena, arguments);
    var result = try baseResult(arena);
    var it = prompt.object.iterator();
    while (it.next()) |entry| try result.object.put(arena, entry.key_ptr.*, entry.value_ptr.*);
    return .{ .result = result };
}

// ---------------------------------------------------------------------------
// Wire
// ---------------------------------------------------------------------------

fn writeResponse(arena: std.mem.Allocator, writer: *std.Io.Writer, id: std.json.Value, outcome: Outcome) !void {
    var response: std.json.ObjectMap = .{};
    try response.put(arena, "jsonrpc", .{ .string = "2.0" });
    try response.put(arena, "id", id);
    switch (outcome) {
        .result => |result| try response.put(arena, "result", result),
        .err => |rpc_error| {
            var err_obj: std.json.ObjectMap = .{};
            try err_obj.put(arena, "code", .{ .integer = rpc_error.code });
            try err_obj.put(arena, "message", .{ .string = rpc_error.message });
            if (rpc_error.data != .null) try err_obj.put(arena, "data", rpc_error.data);
            try response.put(arena, "error", .{ .object = err_obj });
        },
    }
    // Stringify escapes control characters, so a newline inside a string can
    // never split a message across two lines.
    try std.json.Stringify.value(std.json.Value{ .object = response }, .{}, writer);
    try writer.writeByte('\n');
    try writer.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const commands = @import("../commands.zig");

fn testState(arena: std.mem.Allocator) !State {
    return .{
        .gpa = arena,
        .io = std.Io.Threaded.global_single_threaded.io(),
        .root = &commands.root,
        .environ = .empty,
        .tool_list = try tools.collect(arena, &commands.root),
        .confinement = .{},
    };
}

test "initialize echoes a supported legacy version and falls back otherwise" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try testState(arena);

    var params: std.json.ObjectMap = .{};
    try params.put(arena, "protocolVersion", .{ .string = "2025-06-18" });
    const echoed = try dispatch(&state, arena, "initialize", params);
    try std.testing.expectEqualStrings("2025-06-18", echoed.result.object.get("protocolVersion").?.string);

    var future: std.json.ObjectMap = .{};
    try future.put(arena, "protocolVersion", .{ .string = "2030-01-01" });
    const fallback = try dispatch(&state, arena, "initialize", future);
    try std.testing.expectEqualStrings(latest_legacy, fallback.result.object.get("protocolVersion").?.string);
    try std.testing.expect(state.legacy);
}

test "unknown methods and tools are protocol errors" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try testState(arena);

    const missing = try dispatch(&state, arena, "nope/nothing", null);
    try std.testing.expectEqual(@as(i64, -32601), missing.err.code);

    var params: std.json.ObjectMap = .{};
    try params.put(arena, "name", .{ .string = "scene_teleport" });
    const unknown_tool = try dispatch(&state, arena, "tools/call", params);
    try std.testing.expectEqual(@as(i64, -32602), unknown_tool.err.code);
}

test "a modern request naming an unsupported version is refused" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var meta: std.json.ObjectMap = .{};
    try meta.put(arena, "io.modelcontextprotocol/protocolVersion", .{ .string = "2027-01-01" });
    var params: std.json.ObjectMap = .{};
    try params.put(arena, "_meta", .{ .object = meta });
    try std.testing.expectEqualStrings("2027-01-01", unsupportedModernVersion(params).?);

    var ok_meta: std.json.ObjectMap = .{};
    try ok_meta.put(arena, "io.modelcontextprotocol/protocolVersion", .{ .string = "2026-07-28" });
    var ok_params: std.json.ObjectMap = .{};
    try ok_params.put(arena, "_meta", .{ .object = ok_meta });
    try std.testing.expect(unsupportedModernVersion(ok_params) == null);
}

test "a tool call returns the CLI envelope as text and structured content" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try testState(arena);

    var arguments: std.json.ObjectMap = .{};
    try arguments.put(arena, "id", .{ .string = "1350303725746704497" });
    var params: std.json.ObjectMap = .{};
    try params.put(arena, "name", .{ .string = "uid_encode" });
    try params.put(arena, "arguments", .{ .object = arguments });

    const outcome = try dispatch(&state, arena, "tools/call", params);
    const result = outcome.result.object;
    try std.testing.expect(!result.get("isError").?.bool);
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.startsWith(u8, text, "{\"ok\":true,"));
    const structured = result.get("structuredContent").?.object;
    try std.testing.expectEqualStrings("uid://tidkmw585t0t", structured.get("data").?.string);

    // A handler failure is a tool error carrying the failure envelope.
    var bad_args: std.json.ObjectMap = .{};
    try bad_args.put(arena, "id", .{ .string = "not-a-number" });
    var bad_params: std.json.ObjectMap = .{};
    try bad_params.put(arena, "name", .{ .string = "uid_encode" });
    try bad_params.put(arena, "arguments", .{ .object = bad_args });
    const failed = try dispatch(&state, arena, "tools/call", bad_params);
    try std.testing.expect(failed.result.object.get("isError").?.bool);
    try std.testing.expect(failed.result.object.get("structuredContent").?.object.get("failure").? == .object);
}

test "resources and the prompt are listed and readable" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try testState(arena);

    const listed = try dispatch(&state, arena, "resources/list", null);
    try std.testing.expect(listed.result.object.get("resources").?.array.items.len == resources.docs.len + 2);

    var params: std.json.ObjectMap = .{};
    try params.put(arena, "uri", .{ .string = resources.quickstart_uri });
    const read = try dispatch(&state, arena, "resources/read", params);
    const text = read.result.object.get("contents").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "godot-cli agent quickstart") != null);

    var missing: std.json.ObjectMap = .{};
    try missing.put(arena, "uri", .{ .string = "godot-cli://docs/nope" });
    const not_found = try dispatch(&state, arena, "resources/read", missing);
    try std.testing.expectEqual(@as(i64, -32602), not_found.err.code);

    const prompt_list = try dispatch(&state, arena, "prompts/list", null);
    try std.testing.expectEqualStrings(prompts.session_name, prompt_list.result.object.get("prompts").?.array.items[0].object.get("name").?.string);
}

test "responses are one line each with the id echoed" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var state = try testState(arena);

    var out: std.Io.Writer.Allocating = .init(arena);
    try handleLine(&state, arena, "{\"jsonrpc\":\"2.0\",\"id\":\"abc\",\"method\":\"ping\"}", &out.writer);
    try handleLine(&state, arena, "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}", &out.writer);
    try handleLine(&state, arena, "not json", &out.writer);
    const written = out.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, written, "\"id\":\"abc\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "-32700") != null);
}
