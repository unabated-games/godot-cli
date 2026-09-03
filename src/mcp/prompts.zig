//! The one prompt the server offers: a session opener carrying the rules the
//! skill carries, so an agent reached through MCP starts with the same
//! guidance as one reached through the shell. Clients surface it as a slash
//! command under the server's name.

const std = @import("std");
const resources = @import("resources.zig");

pub const session_name = "godot-scene-session";

pub const rules =
    \\You are editing a Godot 4 project through the godot-cli MCP tools. Every tool
    \\returns the same JSON envelope: ok, version, command, data, messages, failure.
    \\A failure carries kind, message, and details naming the field or value to fix.
    \\
    \\Rules:
    \\1. Structure lives in the scene file, as the editor writes it. Never hand-edit
    \\   .tscn, .tres, or project.godot text, and never build static UI or level
    \\   structure in _ready() with load().instantiate(); that is for things the
    \\   game spawns while playing.
    \\2. Discover before editing: scene_node_list for viewport paths
    \\   (/root/<Root>/...), catalog_list and catalog_show for components the
    \\   project already has.
    \\3. A project catalog id is instanced (scene_instance_add with catalog-id); a
    \\   godot/... builtin is a plain node (scene_node_add with type), never instanced.
    \\4. Presentation lives on nodes (anchor_*, grow_*, theme_override_*,
    \\   custom_minimum_size), signals in connection sections (scene_connection_add),
    \\   resources in .tres files (resource_new). None of them in _ready().
    \\5. Values are Godot Variant text: Vector2(1, 2), 1.5, true, and a string
    \\   carries its own quotes, "\"Paused\"". A bare word is rejected before
    \\   anything is written.
    \\6. Move files with project_move, never mv; a plain move leaves every res://
    \\   reference stale.
    \\7. Validate after every edit with scene_validate, then project_run and read
    \\   data.frame (the last PNG) and data.errors before reporting done. It fails
    \\   when the log holds an ERROR or SCRIPT ERROR line.
    \\
    \\Workflow: scene_node_list, catalog_list, edit with one tool call per change
    \\(or scene_apply with an intent for several), scene_validate, then project_run
    \\and read data.frame and data.errors; project_import alone refreshes UIDs after
    \\adding files. Read the godot-cli://docs/quickstart resource before the first edit
    \\and godot-cli://docs/godot-basics before the first UI or level.
;

/// The `prompts/list` entry.
pub fn listJson(allocator: std.mem.Allocator) !std.json.Value {
    var task_arg: std.json.ObjectMap = .{};
    try task_arg.put(allocator, "name", .{ .string = "task" });
    try task_arg.put(allocator, "description", .{ .string = "What to build or change in the project" });
    try task_arg.put(allocator, "required", .{ .bool = false });
    var arguments: std.json.Array = .init(allocator);
    try arguments.append(.{ .object = task_arg });

    var prompt: std.json.ObjectMap = .{};
    try prompt.put(allocator, "name", .{ .string = session_name });
    try prompt.put(allocator, "title", .{ .string = "Godot scene session" });
    try prompt.put(allocator, "description", .{ .string = "Start a scene-authoring session: the rules, the workflow, and the quickstart, with an optional task." });
    try prompt.put(allocator, "arguments", .{ .array = arguments });
    return .{ .object = prompt };
}

/// The `prompts/get` result: one user message with the rules, the quickstart
/// embedded as a resource, and the task if one was given.
pub fn getJson(allocator: std.mem.Allocator, arguments: ?std.json.ObjectMap) !std.json.Value {
    var messages: std.json.Array = .init(allocator);

    try messages.append(try textMessage(allocator, rules));

    const quickstart = resources.find(resources.quickstart_uri).?;
    var resource: std.json.ObjectMap = .{};
    try resource.put(allocator, "uri", .{ .string = quickstart.uri });
    try resource.put(allocator, "mimeType", .{ .string = quickstart.mime });
    try resource.put(allocator, "text", .{ .string = quickstart.text });
    var content: std.json.ObjectMap = .{};
    try content.put(allocator, "type", .{ .string = "resource" });
    try content.put(allocator, "resource", .{ .object = resource });
    var message: std.json.ObjectMap = .{};
    try message.put(allocator, "role", .{ .string = "user" });
    try message.put(allocator, "content", .{ .object = content });
    try messages.append(.{ .object = message });

    if (arguments) |args| {
        if (args.get("task")) |task| {
            if (task == .string and task.string.len != 0) {
                try messages.append(try textMessage(allocator, try std.fmt.allocPrint(allocator, "Task: {s}", .{task.string})));
            }
        }
    }

    var result: std.json.ObjectMap = .{};
    try result.put(allocator, "description", .{ .string = "Godot scene authoring session with godot-cli" });
    try result.put(allocator, "messages", .{ .array = messages });
    return .{ .object = result };
}

fn textMessage(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var content: std.json.ObjectMap = .{};
    try content.put(allocator, "type", .{ .string = "text" });
    try content.put(allocator, "text", .{ .string = text });
    var message: std.json.ObjectMap = .{};
    try message.put(allocator, "role", .{ .string = "user" });
    try message.put(allocator, "content", .{ .object = content });
    return .{ .object = message };
}

test "the session prompt carries the rules, the quickstart, and the task" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args: std.json.ObjectMap = .{};
    try args.put(arena, "task", .{ .string = "add a pause menu" });
    const result = try getJson(arena, args);
    const messages = result.object.get("messages").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].object.get("content").?.object.get("text").?.string, "project_move") != null);
    try std.testing.expectEqualStrings("resource", messages[1].object.get("content").?.object.get("type").?.string);
    try std.testing.expectEqualStrings("Task: add a pause menu", messages[2].object.get("content").?.object.get("text").?.string);
}
