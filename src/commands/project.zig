const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const project_godot = @import("../godot/project_godot.zig");
const project_input = @import("../godot/project_input.zig");
const project_settings = @import("../godot/project_settings.zig");
const project_autoload = @import("../godot/project_autoload.zig");
const project_plugins = @import("../godot/project_plugins.zig");
const project_rendering = @import("../godot/project_rendering.zig");
const project_physics = @import("../godot/project_physics.zig");
const project_unified = @import("../godot/project_unified.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

fn projectRootFrom(inv: *const spec.Invocation) ?[]const u8 {
    return inv.getOption("project-root");
}

fn projectGodotPath(allocator: std.mem.Allocator, project_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ project_root, "project.godot" });
}

fn loadProject(cli: *const app_mod.App, inv: *const spec.Invocation) !struct {
    path: []const u8,
    doc: project_godot.Document,
} {
    const root = projectRootFrom(inv) orelse return error.Usage;
    const path = try projectGodotPath(cli.allocator, root);
    errdefer cli.allocator.free(path);
    const doc = try project_godot.readFile(cli.allocator, cli.io, path);
    return .{ .path = path, .doc = doc };
}

fn inputListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const input = loaded.doc.sectionMut("input") orelse {
        var data: std.json.ObjectMap = .{};
        const empty_actions = std.json.Array.init(cli.allocator);
        try data.put(cli.allocator, "actions", .{ .array = empty_actions });
        try data.put(cli.allocator, "action_count", .{ .integer = 0 });
        try data.put(cli.allocator, "summary", .{ .string = "no [input] section" });
        return .{ .data = .{ .object = data }, .messages = &.{} };
    };

    const actions = try project_input.listActions(cli.allocator, input);
    defer {
        for (actions) |*action| action.deinit(cli.allocator);
        cli.allocator.free(actions);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (actions) |action| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, action.name) });
        try row.put(cli.allocator, "deadzone", .{ .float = action.deadzone });
        try row.put(cli.allocator, "event_count", .{ .integer = @intCast(action.event_count) });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "actions", .{ .array = arr });
    try data.put(cli.allocator, "action_count", .{ .integer = @intCast(actions.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} input action(s)", .{actions.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn inputApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_input.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var names = std.json.Array.init(cli.allocator);
    for (applied.applied_actions) |name| {
        try names.append(.{ .string = try cli.allocator.dupe(u8, name) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_actions", .{ .array = names });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "applied {d} input action(s) ({d} added, {d} replaced)",
        .{ applied.applied_actions.len, applied.added_count, applied.replaced_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn inputValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const input = loaded.doc.sectionMut("input");
    const issue_count = if (input) |section|
        try project_input.validateInputSection(cli.allocator, section)
    else
        @as(usize, 0);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "input map: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

fn settingsListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const section_filter = inv.getOption("section");
    const settings = try project_settings.listAll(cli.allocator, &loaded.doc, section_filter);
    defer {
        for (settings) |*item| item.deinit(cli.allocator);
        cli.allocator.free(settings);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (settings) |item| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "section", .{ .string = try cli.allocator.dupe(u8, item.section) });
        try row.put(cli.allocator, "key", .{ .string = try cli.allocator.dupe(u8, item.key) });
        try row.put(cli.allocator, "value", .{ .string = try cli.allocator.dupe(u8, item.value) });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "settings", .{ .array = arr });
    try data.put(cli.allocator, "setting_count", .{ .integer = @intCast(settings.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} setting(s)", .{settings.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn settingsGetHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const section = inv.getOption("section") orelse return error.Usage;
    const key = inv.getOption("key") orelse return error.Usage;
    const value = project_settings.getSetting(&loaded.doc, section, key);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "section", .{ .string = try cli.allocator.dupe(u8, section) });
    try data.put(cli.allocator, "key", .{ .string = try cli.allocator.dupe(u8, key) });
    try data.put(cli.allocator, "found", .{ .bool = value != null });
    if (value) |text| {
        try data.put(cli.allocator, "value", .{ .string = try cli.allocator.dupe(u8, text) });
    }
    const summary = if (value) |text|
        try std.fmt.allocPrint(cli.allocator, "{s}/{s} = {s}", .{ section, key, text })
    else
        try std.fmt.allocPrint(cli.allocator, "{s}/{s} not found", .{ section, key });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn settingsSetHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const section = inv.getOption("section") orelse return error.Usage;
    const key = inv.getOption("key") orelse return error.Usage;
    const value_text = inv.getOption("value") orelse return error.Usage;

    const replaced = if (inv.flag("raw")) blk: {
        const section_ptr = try loaded.doc.ensureSection(cli.allocator, section);
        const existed = section_ptr.findEntry(key) != null;
        try section_ptr.setEntry(cli.allocator, key, value_text);
        break :blk existed;
    } else blk: {
        break :blk try project_settings.setSetting(cli.allocator, &loaded.doc, section, key, .{ .string = value_text });
    };

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "section", .{ .string = try cli.allocator.dupe(u8, section) });
    try data.put(cli.allocator, "key", .{ .string = try cli.allocator.dupe(u8, key) });
    try data.put(cli.allocator, "value", .{ .string = try cli.allocator.dupe(u8, value_text) });
    try data.put(cli.allocator, "replaced", .{ .bool = replaced });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "set {s}/{s}", .{ section, key });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn settingsApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_settings.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var keys = std.json.Array.init(cli.allocator);
    for (applied.applied_keys) |key| {
        try keys.append(.{ .string = try cli.allocator.dupe(u8, key) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_keys", .{ .array = keys });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "applied {d} setting(s) ({d} added, {d} replaced)",
        .{ applied.applied_keys.len, applied.added_count, applied.replaced_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn settingsValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const section_filter = inv.getOption("section");
    const issue_count = try project_settings.validateSettings(cli.allocator, cli.io, root, &loaded.doc, section_filter);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "project settings: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

fn autoloadListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const section = loaded.doc.sectionMut("autoload") orelse {
        var data: std.json.ObjectMap = .{};
        const empty = std.json.Array.init(cli.allocator);
        try data.put(cli.allocator, "autoloads", .{ .array = empty });
        try data.put(cli.allocator, "autoload_count", .{ .integer = 0 });
        try data.put(cli.allocator, "summary", .{ .string = "no [autoload] section" });
        return .{ .data = .{ .object = data }, .messages = &.{} };
    };

    const autoloads = try project_autoload.listAutoloads(cli.allocator, section);
    defer {
        for (autoloads) |*item| item.deinit(cli.allocator);
        cli.allocator.free(autoloads);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (autoloads) |item| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, item.name) });
        try row.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, item.path) });
        try row.put(cli.allocator, "singleton", .{ .bool = item.singleton });
        try row.put(cli.allocator, "order", .{ .integer = @intCast(item.order) });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "autoloads", .{ .array = arr });
    try data.put(cli.allocator, "autoload_count", .{ .integer = @intCast(autoloads.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} autoload(s)", .{autoloads.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn autoloadApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_autoload.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var names = std.json.Array.init(cli.allocator);
    for (applied.applied_names) |name| {
        try names.append(.{ .string = try cli.allocator.dupe(u8, name) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_names", .{ .array = names });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "removed_count", .{ .integer = @intCast(applied.removed_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "applied {d} autoload(s) ({d} added, {d} replaced, {d} removed)",
        .{ applied.applied_names.len, applied.added_count, applied.replaced_count, applied.removed_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn autoloadValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const section = loaded.doc.sectionMut("autoload");
    const issue_count = if (section) |sec|
        try project_autoload.validateAutoloadSection(cli.allocator, cli.io, root, sec)
    else
        @as(usize, 0);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "autoloads: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

fn pluginsListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const plugins = try project_plugins.listPlugins(cli.allocator, cli.io, root, loaded.doc.sectionMut("editor_plugins"));
    defer {
        for (plugins) |*plugin| plugin.deinit(cli.allocator);
        cli.allocator.free(plugins);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (plugins) |plugin| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, plugin.name) });
        try row.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, plugin.path) });
        try row.put(cli.allocator, "enabled", .{ .bool = plugin.enabled });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "plugins", .{ .array = arr });
    try data.put(cli.allocator, "plugin_count", .{ .integer = @intCast(plugins.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} plugin(s)", .{plugins.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn pluginsEnableHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const plugin = inv.getOption("plugin") orelse inv.getOption("path") orelse return error.Usage;
    const added = try project_plugins.enablePlugin(cli.allocator, &loaded.doc, plugin);

    if (!inv.flag("dry-run") and added) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "plugin", .{ .string = try cli.allocator.dupe(u8, plugin) });
    try data.put(cli.allocator, "enabled", .{ .bool = added });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = if (added) "enabled plugin" else "plugin already enabled";
    try data.put(cli.allocator, "summary", .{ .string = try cli.allocator.dupe(u8, summary) });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn pluginsDisableHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const plugin = inv.getOption("plugin") orelse inv.getOption("path") orelse return error.Usage;
    const removed = try project_plugins.disablePlugin(cli.allocator, &loaded.doc, plugin);

    if (!inv.flag("dry-run") and removed) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "plugin", .{ .string = try cli.allocator.dupe(u8, plugin) });
    try data.put(cli.allocator, "disabled", .{ .bool = removed });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = if (removed) "disabled plugin" else "plugin was not enabled";
    try data.put(cli.allocator, "summary", .{ .string = try cli.allocator.dupe(u8, summary) });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn pluginsApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_plugins.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var paths = std.json.Array.init(cli.allocator);
    for (applied.enabled_paths) |path| {
        try paths.append(.{ .string = try cli.allocator.dupe(u8, path) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "enabled_paths", .{ .array = paths });
    try data.put(cli.allocator, "enabled_count", .{ .integer = @intCast(applied.enabled_count) });
    try data.put(cli.allocator, "disabled_count", .{ .integer = @intCast(applied.disabled_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "plugins: {d} enabled, {d} disabled",
        .{ applied.enabled_count, applied.disabled_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn pluginsValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const issue_count = try project_plugins.validatePlugins(cli.allocator, cli.io, root, loaded.doc.sectionMut("editor_plugins"));

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "editor plugins: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

fn renderingListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const settings = try project_settings.listAll(cli.allocator, &loaded.doc, "rendering");
    defer {
        for (settings) |*item| item.deinit(cli.allocator);
        cli.allocator.free(settings);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (settings) |item| {
        var row: std.json.ObjectMap = .{};
        const alias = project_rendering.aliasForKey(item.key);
        if (alias) |name| try row.put(cli.allocator, "alias", .{ .string = try cli.allocator.dupe(u8, name) });
        try row.put(cli.allocator, "key", .{ .string = try cli.allocator.dupe(u8, item.key) });
        try row.put(cli.allocator, "value", .{ .string = try cli.allocator.dupe(u8, item.value) });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "settings", .{ .array = arr });
    try data.put(cli.allocator, "setting_count", .{ .integer = @intCast(settings.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} rendering setting(s)", .{settings.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn renderingApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_rendering.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var keys = std.json.Array.init(cli.allocator);
    for (applied.applied_keys) |key| {
        try keys.append(.{ .string = try cli.allocator.dupe(u8, key) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_keys", .{ .array = keys });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(
        cli.allocator,
        "applied {d} rendering setting(s)",
        .{applied.applied_keys.len},
    );
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn renderingValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const issue_count = project_rendering.validateRenderingSection(&loaded.doc);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "rendering: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

fn showHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    var summary = try project_unified.buildSummary(cli.allocator, cli.io, root, &loaded.doc);
    defer summary.deinit(cli.allocator);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    if (summary.project_name) |name| try data.put(cli.allocator, "project_name", .{ .string = try cli.allocator.dupe(u8, name) });
    if (summary.main_scene) |scene| try data.put(cli.allocator, "main_scene", .{ .string = try cli.allocator.dupe(u8, scene) });
    try data.put(cli.allocator, "input_action_count", .{ .integer = @intCast(summary.input_action_count) });
    try data.put(cli.allocator, "autoload_count", .{ .integer = @intCast(summary.autoload_count) });
    try data.put(cli.allocator, "enabled_plugin_count", .{ .integer = @intCast(summary.enabled_plugin_count) });
    if (summary.rendering_method) |method| try data.put(cli.allocator, "rendering_method", .{ .string = try cli.allocator.dupe(u8, method) });
    if (summary.physics_engine_3d) |engine| try data.put(cli.allocator, "physics_engine_3d", .{ .string = try cli.allocator.dupe(u8, engine) });

    const text = try std.fmt.allocPrint(
        cli.allocator,
        "project summary: {d} input actions, {d} autoloads, {d} plugins",
        .{ summary.input_action_count, summary.autoload_count, summary.enabled_plugin_count },
    );
    try data.put(cli.allocator, "summary", .{ .string = text });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn projectApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_unified.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var sections = std.json.Array.init(cli.allocator);
    for (applied.sections) |section| {
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, section.name) });
        try row.put(cli.allocator, "summary", .{ .string = try cli.allocator.dupe(u8, section.summary) });
        try sections.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "sections", .{ .array = sections });
    try data.put(cli.allocator, "section_count", .{ .integer = @intCast(applied.sections.len) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "applied {d} project section(s)", .{applied.sections.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn physicsListHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const settings = try project_settings.listAll(cli.allocator, &loaded.doc, "physics");
    defer {
        for (settings) |*item| item.deinit(cli.allocator);
        cli.allocator.free(settings);
    }

    var arr = std.json.Array.init(cli.allocator);
    for (settings) |item| {
        var row: std.json.ObjectMap = .{};
        const alias = project_physics.aliasForKey(item.key);
        if (alias) |name| try row.put(cli.allocator, "alias", .{ .string = try cli.allocator.dupe(u8, name) });
        try row.put(cli.allocator, "key", .{ .string = try cli.allocator.dupe(u8, item.key) });
        try row.put(cli.allocator, "value", .{ .string = try cli.allocator.dupe(u8, item.value) });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "settings", .{ .array = arr });
    try data.put(cli.allocator, "setting_count", .{ .integer = @intCast(settings.len) });
    const summary = try std.fmt.allocPrint(cli.allocator, "listed {d} physics setting(s)", .{settings.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn physicsApplyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const intent_path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const intent_bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, intent_path, cli.allocator, .unlimited) catch return error.Io;
    defer cli.allocator.free(intent_bytes);

    var applied = try project_physics.applyIntentJson(cli.allocator, &loaded.doc, intent_bytes);
    defer applied.deinit(cli.allocator);

    if (!inv.flag("dry-run")) {
        try project_godot.writeFile(cli.allocator, cli.io, loaded.path, &loaded.doc);
    }

    var keys = std.json.Array.init(cli.allocator);
    for (applied.applied_keys) |key| {
        try keys.append(.{ .string = try cli.allocator.dupe(u8, key) });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_keys", .{ .array = keys });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "applied {d} physics setting(s)", .{applied.applied_keys.len});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn physicsValidateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    var loaded = try loadProject(cli, inv);
    defer cli.allocator.free(loaded.path);
    defer loaded.doc.deinit(cli.allocator);

    const issue_count = project_physics.validatePhysicsSection(&loaded.doc);

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "issue_count", .{ .integer = @intCast(issue_count) });
    try data.put(cli.allocator, "ok", .{ .bool = issue_count == 0 });
    const summary = try std.fmt.allocPrint(cli.allocator, "physics: {d} issue(s)", .{issue_count});
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{
        .data = .{ .object = data },
        .messages = &.{},
        .exit_code = if (issue_count > 0) .failure else .success,
    };
}

pub fn commands() spec.CommandSpec {
    const project_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
    };

    const intent_apply_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "intent", .kind = .path, .description = "Intent JSON file" },
        .{ .long = "file", .kind = .path, .description = "Alias for --intent" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };

    const settings_list_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "section", .kind = .string, .description = "Filter to one section (application, display, layer_names, …)" },
    };

    const settings_get_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "section", .kind = .string, .description = "Section name (e.g. application)" },
        .{ .long = "key", .kind = .string, .description = "Setting key (e.g. run/main_scene)" },
    };

    const settings_set_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "section", .kind = .string, .description = "Section name (e.g. application)" },
        .{ .long = "key", .kind = .string, .description = "Setting key (e.g. run/main_scene)" },
        .{ .long = "value", .kind = .string, .description = "Plain value (quoted automatically for strings)" },
        .{ .long = "raw", .kind = .flag, .description = "Store --value verbatim (already Godot-formatted)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };

    const plugin_toggle_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "plugin", .kind = .string, .description = "Plugin path or addon folder name (res://addons/.../plugin.cfg)" },
        .{ .long = "path", .kind = .string, .description = "Alias for --plugin" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };

    return .{
        .name = "project",
        .summary = "Read and write Godot project.godot settings",
        .description = "Project-level configuration: input, autoloads, plugins, rendering, physics, display, layer names.",
        .options = &project_options,
        .children = &.{
            .{
                .name = "show",
                .summary = "Summarize key project.godot configuration",
                .options = &project_options,
                .handler = showHandler,
            },
            .{
                .name = "apply",
                .summary = "Apply unified project intent JSON (input, settings, autoload, plugins, rendering, physics)",
                .options = &intent_apply_options,
                .handler = projectApplyHandler,
            },
            .{
                .name = "input",
                .summary = "Input Map actions in project.godot",
                .children = &.{
                    .{ .name = "list", .summary = "List input actions", .options = &project_options, .handler = inputListHandler },
                    .{ .name = "apply", .summary = "Apply input map intent JSON (merge/replace per action)", .options = &intent_apply_options, .handler = inputApplyHandler },
                    .{ .name = "validate", .summary = "Validate [input] section event objects", .options = &project_options, .handler = inputValidateHandler },
                },
            },
            .{
                .name = "settings",
                .summary = "Scalar project settings (application, display, layer_names, …)",
                .children = &.{
                    .{ .name = "list", .summary = "List settings (optional --section filter)", .options = &settings_list_options, .handler = settingsListHandler },
                    .{ .name = "get", .summary = "Get one setting value", .options = &settings_get_options, .handler = settingsGetHandler },
                    .{ .name = "set", .summary = "Set one setting value", .options = &settings_set_options, .handler = settingsSetHandler },
                    .{ .name = "apply", .summary = "Apply settings intent JSON (per-key merge)", .options = &intent_apply_options, .handler = settingsApplyHandler },
                    .{ .name = "validate", .summary = "Validate res:// paths in settings", .options = &settings_list_options, .handler = settingsValidateHandler },
                },
            },
            .{
                .name = "autoload",
                .summary = "Autoload singletons in project.godot",
                .children = &.{
                    .{ .name = "list", .summary = "List autoload entries", .options = &project_options, .handler = autoloadListHandler },
                    .{ .name = "apply", .summary = "Apply autoload intent JSON (merge by name; optional replace_all)", .options = &intent_apply_options, .handler = autoloadApplyHandler },
                    .{ .name = "validate", .summary = "Validate autoload paths and names", .options = &project_options, .handler = autoloadValidateHandler },
                },
            },
            .{
                .name = "plugins",
                .summary = "Editor plugins enable/disable in project.godot",
                .children = &.{
                    .{ .name = "list", .summary = "List addons and enabled state", .options = &project_options, .handler = pluginsListHandler },
                    .{ .name = "enable", .summary = "Enable one plugin", .options = &plugin_toggle_options, .handler = pluginsEnableHandler },
                    .{ .name = "disable", .summary = "Disable one plugin", .options = &plugin_toggle_options, .handler = pluginsDisableHandler },
                    .{ .name = "apply", .summary = "Apply plugin intent JSON (enable/disable lists)", .options = &intent_apply_options, .handler = pluginsApplyHandler },
                    .{ .name = "validate", .summary = "Validate enabled plugin paths exist", .options = &project_options, .handler = pluginsValidateHandler },
                },
            },
            .{
                .name = "rendering",
                .summary = "Rendering method and graphics driver settings",
                .children = &.{
                    .{ .name = "list", .summary = "List [rendering] section settings", .options = &project_options, .handler = renderingListHandler },
                    .{ .name = "apply", .summary = "Apply rendering intent JSON (friendly aliases)", .options = &intent_apply_options, .handler = renderingApplyHandler },
                    .{ .name = "validate", .summary = "Validate known rendering method/driver values", .options = &project_options, .handler = renderingValidateHandler },
                },
            },
            .{
                .name = "physics",
                .summary = "Physics engine and gravity settings",
                .children = &.{
                    .{ .name = "list", .summary = "List [physics] section settings", .options = &project_options, .handler = physicsListHandler },
                    .{ .name = "apply", .summary = "Apply physics intent JSON (friendly aliases)", .options = &intent_apply_options, .handler = physicsApplyHandler },
                    .{ .name = "validate", .summary = "Validate known physics engine and scalar values", .options = &project_options, .handler = physicsValidateHandler },
                },
            },
        },
    };
}
