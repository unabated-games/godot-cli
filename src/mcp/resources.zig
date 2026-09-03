//! Documents the server exposes as MCP resources: the agent docs and the
//! copy-paste intents, embedded at build time so the binary carries them.
//! `build.zig` registers each file as an anonymous import under the name used
//! here; `godot-cli://catalog` is produced live by `server.zig`.

pub const Doc = struct {
    uri: []const u8,
    name: []const u8,
    title: []const u8,
    description: []const u8,
    mime: []const u8,
    text: []const u8,
};

pub const quickstart_uri = "godot-cli://docs/quickstart";

pub const docs = [_]Doc{
    .{
        .uri = quickstart_uri,
        .name = "quickstart",
        .title = "Agent quickstart",
        .description = "One page: the rules, the workflow, a cheat sheet, and what to read next. Read this first.",
        .mime = "text/markdown",
        .text = @embedFile("doc_quickstart"),
    },
    .{
        .uri = "godot-cli://docs/godot-basics",
        .name = "godot-basics",
        .title = "Godot basics for agents",
        .description = "What Godot assumes about projects, scenes, and Control layout, and how to run the game and read the result.",
        .mime = "text/markdown",
        .text = @embedFile("doc_godot_basics"),
    },
    .{
        .uri = "godot-cli://docs/scene-authoring",
        .name = "scene-authoring",
        .title = "Scene authoring reference",
        .description = "Every recipe and patch op, resources, moving files, UI editor parity, follow-ups, and anti-patterns.",
        .mime = "text/markdown",
        .text = @embedFile("doc_scene_authoring"),
    },
    .{
        .uri = "godot-cli://docs/batch",
        .name = "batch",
        .title = "Batch commands",
        .description = "Running several commands in one process with stop, continue, or atomic mode.",
        .mime = "text/markdown",
        .text = @embedFile("doc_batch_commands"),
    },
    .{
        .uri = "godot-cli://docs/commands",
        .name = "commands",
        .title = "Command reference",
        .description = "Every command and option, generated from the command tree.",
        .mime = "text/markdown",
        .text = @embedFile("doc_commands"),
    },
    .{
        .uri = "godot-cli://docs/mcp-tools",
        .name = "mcp-tools",
        .title = "Tool catalog with worked requests",
        .description = "One worked argv per command, the same names as the tools here.",
        .mime = "application/json",
        .text = @embedFile("doc_mcp_tools"),
    },
    .{ .uri = "godot-cli://examples/intents/assign_sprite_texture.json", .name = "assign_sprite_texture", .title = "Intent: assign a sprite texture", .description = "Copy-paste intent for scene apply --intent.", .mime = "application/json", .text = @embedFile("example_assign_sprite_texture") },
    .{ .uri = "godot-cli://examples/intents/autoload_game_state.json", .name = "autoload_game_state", .title = "Intent: register an autoload", .description = "Copy-paste intent for project autoload apply.", .mime = "application/json", .text = @embedFile("example_autoload_game_state") },
    .{ .uri = "godot-cli://examples/intents/catalog_button.json", .name = "catalog_button", .title = "Intent: instance a catalog button", .description = "Copy-paste intent for scene apply --intent.", .mime = "application/json", .text = @embedFile("example_catalog_button") },
    .{ .uri = "godot-cli://examples/intents/display_stretch.json", .name = "display_stretch", .title = "Intent: display and stretch settings", .description = "Copy-paste intent for project settings apply.", .mime = "application/json", .text = @embedFile("example_display_stretch") },
    .{ .uri = "godot-cli://examples/intents/enable_sample_plugin.json", .name = "enable_sample_plugin", .title = "Intent: enable a plugin", .description = "Copy-paste intent for project plugins apply.", .mime = "application/json", .text = @embedFile("example_enable_sample_plugin") },
    .{ .uri = "godot-cli://examples/intents/hud_main.json", .name = "hud_main", .title = "Intent: player and camera", .description = "Copy-paste intent for scene apply --intent.", .mime = "application/json", .text = @embedFile("example_hud_main") },
    .{ .uri = "godot-cli://examples/intents/hud_top_bar.json", .name = "hud_top_bar", .title = "Intent: HUD top bar", .description = "Copy-paste intent for scene apply --intent.", .mime = "application/json", .text = @embedFile("example_hud_top_bar") },
    .{ .uri = "godot-cli://examples/intents/main_scene.json", .name = "main_scene", .title = "Intent: set the main scene", .description = "Copy-paste intent for project settings apply.", .mime = "application/json", .text = @embedFile("example_main_scene") },
    .{ .uri = "godot-cli://examples/intents/physics_jolt.json", .name = "physics_jolt", .title = "Intent: Jolt physics", .description = "Copy-paste intent for project physics apply.", .mime = "application/json", .text = @embedFile("example_physics_jolt") },
    .{ .uri = "godot-cli://examples/intents/physics_layers.json", .name = "physics_layers", .title = "Intent: physics layer names", .description = "Copy-paste intent for project settings apply.", .mime = "application/json", .text = @embedFile("example_physics_layers") },
    .{ .uri = "godot-cli://examples/intents/player_with_icon.json", .name = "player_with_icon", .title = "Intent: player with icon texture", .description = "Copy-paste intent for scene apply --intent.", .mime = "application/json", .text = @embedFile("example_player_with_icon") },
    .{ .uri = "godot-cli://examples/intents/project_bootstrap.json", .name = "project_bootstrap", .title = "Intent: project bootstrap", .description = "Copy-paste intent for project apply: settings, input, autoload, rendering, physics.", .mime = "application/json", .text = @embedFile("example_project_bootstrap") },
    .{ .uri = "godot-cli://examples/intents/rendering_forward_plus.json", .name = "rendering_forward_plus", .title = "Intent: Forward+ rendering", .description = "Copy-paste intent for project rendering apply.", .mime = "application/json", .text = @embedFile("example_rendering_forward_plus") },
    .{ .uri = "godot-cli://examples/intents/wasd_movement.json", .name = "wasd_movement", .title = "Intent: WASD and joypad input map", .description = "Copy-paste intent for project input apply.", .mime = "application/json", .text = @embedFile("example_wasd_movement") },
    .{ .uri = "godot-cli://examples/patches/sprite_icon_texture.json", .name = "sprite_icon_texture", .title = "Patch: sprite icon texture", .description = "Copy-paste patch for scene apply --patch.", .mime = "application/json", .text = @embedFile("example_sprite_icon_texture") },
};

pub fn find(uri: []const u8) ?*const Doc {
    for (&docs) |*doc| if (@import("std").mem.eql(u8, doc.uri, uri)) return doc;
    return null;
}

test "every embedded resource has content and a unique uri" {
    const std = @import("std");
    for (docs, 0..) |doc, index| {
        try std.testing.expect(doc.text.len > 0);
        try std.testing.expect(std.mem.startsWith(u8, doc.uri, "godot-cli://"));
        for (docs[index + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, doc.uri, other.uri));
    }
    try std.testing.expect(std.mem.indexOf(u8, find(quickstart_uri).?.text, "godot-cli agent quickstart") != null);
}
