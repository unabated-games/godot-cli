const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const project_godot = @import("../godot/project_godot.zig");
const error_details = @import("../godot/error_details.zig");
const io_util = @import("../io_util.zig");
const godot_run = @import("../godot/godot_run.zig");
const project_input = @import("../godot/project_input.zig");
const project_settings = @import("../godot/project_settings.zig");
const project_autoload = @import("../godot/project_autoload.zig");
const project_plugins = @import("../godot/project_plugins.zig");
const project_rendering = @import("../godot/project_rendering.zig");
const project_physics = @import("../godot/project_physics.zig");
const project_unified = @import("../godot/project_unified.zig");
const project_move = @import("../godot/project_move.zig");

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
    const doc = project_godot.readFile(cli.allocator, cli.io, path) catch |err| switch (err) {
        error.Io => {
            // `path` is deliberately not freed here: the detail borrows it
            // until the failure is serialised.
            error_details.record(.{
                .field = "project.godot",
                .value = path,
                .hint = "no readable project.godot at this path; create one with `project new`, or pass --project-root",
            });
            return error.FileNotFound;
        },
        else => {
            cli.allocator.free(path);
            return err;
        },
    };
    return .{ .path = path, .doc = doc };
}

const IntentSource = struct { label: []const u8, bytes: []const u8 };

/// `--intent-json` carries the document itself; otherwise `--intent` (or the
/// older `--file`) names a file. A missing file reports its path.
fn readIntentSource(cli: *const app_mod.App, inv: *const spec.Invocation) !IntentSource {
    if (inv.getOption("intent-json")) |text| {
        return .{ .label = "inline", .bytes = try cli.allocator.dupe(u8, text) };
    }
    const path = inv.getOption("intent") orelse inv.getOption("file") orelse return error.Usage;
    const bytes = std.Io.Dir.cwd().readFileAlloc(cli.io, path, cli.allocator, .unlimited) catch {
        error_details.record(.{
            .field = "intent",
            .value = path,
            .hint = "intent file not found; pass a path relative to the working directory, or the JSON itself with --intent-json",
        });
        return error.FileNotFound;
    };
    return .{ .label = path, .bytes = bytes };
}

fn runDataCommon(cli: *const app_mod.App, data: *std.json.ObjectMap, run: godot_run.Result) !void {
    try data.put(cli.allocator, "godot", .{ .string = run.godot });
    if (run.import_exit) |code| try data.put(cli.allocator, "import_exit", .{ .integer = code });
    if (run.exit) |code| try data.put(cli.allocator, "exit", .{ .integer = code });
    if (run.signal) |sig| try data.put(cli.allocator, "signal", .{ .string = sig });
    try data.put(cli.allocator, "log", .{ .string = run.log_path });
    var errors: std.json.Array = .init(cli.allocator);
    for (run.errors) |line| try errors.append(.{ .string = line });
    try data.put(cli.allocator, "error_count", .{ .integer = @intCast(run.errors.len) });
    try data.put(cli.allocator, "errors", .{ .array = errors });
    if (run.stderr_tail.len != 0) try data.put(cli.allocator, "stderr_tail", .{ .string = run.stderr_tail });
    try data.put(cli.allocator, "duration_ms", .{ .integer = run.duration_ms });
}

fn importHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse ".";
    const godot = try godot_run.locateGodot(cli.allocator, cli.io, cli.environ, inv.getOption("godot"));
    const started = std.Io.Clock.Timestamp.now(cli.io, .real);
    const outcome = try godot_run.runProcess(cli.allocator, cli.environ, root, &.{ godot, "--headless", "--path", ".", "--import", "--quit" });
    const code: ?u8 = switch (outcome.term) {
        .exited => |c| c,
        else => null,
    };
    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "godot", .{ .string = godot });
    if (code) |c| try data.put(cli.allocator, "exit", .{ .integer = c });
    try data.put(cli.allocator, "duration_ms", .{ .integer = started.durationTo(.now(cli.io, .real)).raw.toMilliseconds() });
    const ok = code != null and code.? == 0;
    try data.put(cli.allocator, "summary", .{ .string = if (ok) "imported project resources" else "godot import exited with an error" });
    if (!ok) try data.put(cli.allocator, "stderr_tail", .{ .string = outcome.stderr });
    return .{ .data = .{ .object = data }, .exit_code = if (ok) .success else .failure };
}

fn runHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse ".";
    const frames = std.fmt.parseInt(u32, inv.getOption("frames") orelse "60", 10) catch return error.InvalidValue;
    const user_args = try inv.getOptionAll(cli.allocator, "user-arg");

    const press_texts = try inv.getOptionAll(cli.allocator, "press");
    var presses: std.ArrayList(godot_run.Press) = .empty;
    for (press_texts) |text| {
        const press = godot_run.parsePress(text) orelse {
            error_details.record(.{ .field = "press", .value = text, .hint = "write <action>@<frame> or <action>@<first>..<last>, frames counted from 1, e.g. move_right@10..40" });
            return error.InvalidPropertyValue;
        };
        try presses.append(cli.allocator, press);
    }

    const click_texts = try inv.getOptionAll(cli.allocator, "click");
    var clicks: std.ArrayList(godot_run.Click) = .empty;
    for (click_texts) |text| {
        const click = godot_run.parseClick(text) orelse {
            error_details.record(.{ .field = "click", .value = text, .hint = "write <node path>@<frame>, e.g. /root/Main/HUD/PauseButton@20" });
            return error.InvalidPropertyValue;
        };
        try clicks.append(cli.allocator, click);
    }

    // The project's own window size is the right default; a fixed one would
    // silently run a 1280x720 project at 640x360.
    var main_scene: ?[]const u8 = null;
    var project_resolution: ?[]const u8 = null;
    if (loadProject(cli, inv)) |loaded_const| {
        var loaded = loaded_const;
        defer loaded.doc.deinit(cli.allocator);
        if (loaded.doc.sectionMut("application")) |app| {
            if (app.getEntry("run/main_scene")) |value| main_scene = try cli.allocator.dupe(u8, project_godot.unquoteValue(value) orelse value);
        }
        if (loaded.doc.sectionMut("display")) |display| {
            if (display.getEntry("window/size/viewport_width")) |w| if (display.getEntry("window/size/viewport_height")) |h| {
                project_resolution = try std.fmt.allocPrint(cli.allocator, "{s}x{s}", .{ w, h });
            };
        }
    } else |_| {}

    const run = try godot_run.run(cli.allocator, cli.io, cli.environ, .{
        .project_root = root,
        .godot = inv.getOption("godot"),
        .scene = inv.getOption("scene"),
        .frames = frames,
        .resolution = inv.getOption("resolution") orelse project_resolution orelse "640x360",
        .capture_dir = inv.getOption("capture-dir") orelse godot_run.default_capture_dir,
        .import = !inv.flag("no-import"),
        .keep_frames = inv.flag("keep-frames"),
        .headless = inv.flag("headless"),
        .user_args = user_args,
        .presses = presses.items,
        .clicks = clicks.items,
        .main_scene = main_scene,
    });

    var data: std.json.ObjectMap = .{};
    try runDataCommon(cli, &data, run);
    if (inv.getOption("scene")) |scene| try data.put(cli.allocator, "scene", .{ .string = scene });
    try data.put(cli.allocator, "frames_requested", .{ .integer = frames });
    try data.put(cli.allocator, "frames_written", .{ .integer = @intCast(run.frames_written) });
    if (run.frame) |frame| try data.put(cli.allocator, "frame", .{ .string = frame });
    try data.put(cli.allocator, "presses", .{ .integer = @intCast(presses.items.len) });
    try data.put(cli.allocator, "clicks", .{ .integer = @intCast(clicks.items.len) });
    if (run.driver_script) |script| try data.put(cli.allocator, "driver_script", .{ .string = script });
    if (run.log_tail.len != 0) try data.put(cli.allocator, "log_tail", .{ .string = run.log_tail });

    const clean_exit = run.exit != null and run.exit.? == 0;
    const ok = clean_exit and run.errors.len == 0;
    const summary = if (ok)
        try std.fmt.allocPrint(cli.allocator, "ran {d} frame(s) with no errors; read {s}", .{ frames, run.frame orelse run.log_path })
    else if (!clean_exit)
        try std.fmt.allocPrint(cli.allocator, "godot did not exit cleanly (exit {?d}); see stderr_tail and {s}", .{ run.exit, run.log_path })
    else
        try std.fmt.allocPrint(cli.allocator, "{d} error line(s) in {s}; the change is not done", .{ run.errors.len, run.log_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .exit_code = if (ok) .success else .failure };
}

fn newHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse ".";
    const name = inv.getOption("name") orelse return error.Usage;
    const path = try projectGodotPath(cli.allocator, root);

    if (std.Io.Dir.cwd().access(cli.io, path, .{})) |_| {
        error_details.record(.{
            .field = "project.godot",
            .value = path,
            .hint = "a project.godot already exists here; change it with `project settings set` or `project apply`",
        });
        return error.AlreadyExists;
    } else |_| {}

    // The header the project manager writes, then the sections in the order
    // Godot saves them. Parsing it back and writing through the project.godot
    // writer keeps the layout identical to what a later edit produces.
    var text: std.Io.Writer.Allocating = .init(cli.allocator);
    const w = &text.writer;
    try w.writeAll(
        \\; Engine configuration file.
        \\; It's best edited using the editor UI and not directly,
        \\; since the parameters that go here are not all obvious.
        \\;
        \\; Format:
        \\;   [section] ; section goes between []
        \\;   param=value ; assign values to parameters
        \\
        \\config_version=5
        \\
        \\[application]
        \\
        \\
    );
    const quoted_name = try project_godot.formatQuotedString(cli.allocator, name);
    try w.print("config/name={s}\n", .{quoted_name});
    if (inv.getOption("main-scene")) |main_scene| {
        const quoted_scene = try project_godot.formatQuotedString(cli.allocator, main_scene);
        try w.print("run/main_scene={s}\n", .{quoted_scene});
    }
    const width = inv.getOption("width");
    const height = inv.getOption("height");
    if (width != null or height != null) {
        try w.writeAll("\n[display]\n\n");
        if (width) |value| {
            _ = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            try w.print("window/size/viewport_width={s}\n", .{value});
        }
        if (height) |value| {
            _ = std.fmt.parseInt(u32, value, 10) catch return error.InvalidValue;
            try w.print("window/size/viewport_height={s}\n", .{value});
        }
    }

    var doc = try project_godot.parseBytes(cli.allocator, text.written());
    defer doc.deinit(cli.allocator);

    var wrote_icon = false;
    if (!inv.flag("dry-run")) {
        std.Io.Dir.cwd().createDirPath(cli.io, root) catch {};
        try project_godot.writeFile(cli.allocator, cli.io, path, &doc);
        // The project manager drops icon.svg beside project.godot, and the
        // examples reference res://icon.svg; write it unless one exists.
        if (!inv.flag("no-icon")) {
            const icon_path = try std.fs.path.join(cli.allocator, &.{ root, "icon.svg" });
            if (std.Io.Dir.cwd().access(cli.io, icon_path, .{})) |_| {} else |_| {
                io_util.writeFileAtomic(cli.io, icon_path, default_icon_svg) catch return error.Io;
                wrote_icon = true;
            }
        }
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = path });
    try data.put(cli.allocator, "name", .{ .string = name });
    if (inv.getOption("main-scene")) |main_scene| try data.put(cli.allocator, "main_scene", .{ .string = main_scene });
    try data.put(cli.allocator, "icon_written", .{ .bool = wrote_icon });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    try data.put(cli.allocator, "summary", .{ .string = try std.fmt.allocPrint(cli.allocator, "created {s}{s}", .{ path, if (wrote_icon) " and icon.svg" else "" }) });
    return .{ .data = .{ .object = data } };
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

fn moveHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse return error.Usage;
    const from = inv.getOption("from") orelse return error.Usage;
    const to = inv.getOption("to") orelse return error.Usage;

    var result = try project_move.moveResource(cli.allocator, cli.io, root, from, to, inv.flag("dry-run"));
    defer result.deinit(cli.allocator);

    var files = std.json.Array.init(cli.allocator);
    for (result.changed_files) |f| try files.append(.{ .string = try cli.allocator.dupe(u8, f) });

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "from", .{ .string = try cli.allocator.dupe(u8, result.from) });
    try data.put(cli.allocator, "to", .{ .string = try cli.allocator.dupe(u8, result.to) });
    try data.put(cli.allocator, "sidecars_moved", .{ .integer = @intCast(result.sidecars_moved) });
    try data.put(cli.allocator, "files_changed", .{ .integer = @intCast(result.files_changed) });
    try data.put(cli.allocator, "references_retargeted", .{ .integer = @intCast(result.references_retargeted) });
    try data.put(cli.allocator, "manifests_updated", .{ .integer = @intCast(result.manifests_updated) });
    try data.put(cli.allocator, "settings_updated", .{ .integer = @intCast(result.settings_updated) });
    try data.put(cli.allocator, "changed_files", .{ .array = files });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try std.fmt.allocPrint(cli.allocator, "moved {s} to {s}; retargeted {d} reference(s) in {d} file(s), {d} manifest(s), {d} setting(s)", .{ result.from, result.to, result.references_retargeted, result.files_changed, result.manifests_updated, result.settings_updated });
    try data.put(cli.allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .messages = &.{} };
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
    if (std.Io.Dir.cwd().realPathFileAlloc(cli.io, root, cli.allocator)) |absolute| {
        try data.put(cli.allocator, "project_root", .{ .string = absolute });
    } else |_| {}
    if (summary.project_name) |name| try data.put(cli.allocator, "project_name", .{ .string = try cli.allocator.dupe(u8, name) });
    if (summary.main_scene) |scene| try data.put(cli.allocator, "main_scene", .{ .string = try cli.allocator.dupe(u8, scene) });
    if (loaded.doc.sectionMut("display")) |display| {
        var window: std.json.ObjectMap = .{};
        const keys = [_][]const u8{ "window/size/viewport_width", "window/size/viewport_height", "window/stretch/mode", "window/stretch/aspect" };
        for (keys) |key| {
            if (display.getEntry(key)) |value| {
                const short = key[std.mem.lastIndexOfScalar(u8, key, '/').? + 1 ..];
                const unquoted = project_godot.unquoteValue(value) orelse value;
                try window.put(cli.allocator, try cli.allocator.dupe(u8, short), .{ .string = try cli.allocator.dupe(u8, unquoted) });
            }
        }
        if (window.count() != 0) try data.put(cli.allocator, "window", .{ .object = window });
    }
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

    const intent_source = try readIntentSource(cli, inv);
    const intent_path = intent_source.label;
    const intent_bytes = intent_source.bytes;
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

const new_options = [_]spec.OptionSpec{
    .{ .long = "project-root", .kind = .path, .description = "Folder to create the project in (default: current directory)" },
    .{ .long = "name", .kind = .string, .description = "Project name (application/config/name)", .required = true },
    .{ .long = "main-scene", .kind = .string, .description = "Main scene as a res:// path (application/run/main_scene)" },
    .{ .long = "width", .kind = .integer, .description = "Viewport width in pixels (display/window/size/viewport_width)" },
    .{ .long = "height", .kind = .integer, .description = "Viewport height in pixels (display/window/size/viewport_height)" },
    .{ .long = "dry-run", .kind = .flag, .description = "Report what would be written without creating the file" },
    .{ .long = "no-icon", .kind = .flag, .description = "Do not write the default icon.svg beside project.godot" },
};

/// Godot's own default project icon (editor/icons/DefaultProjectIcon.svg).
const default_icon_svg = @embedFile("default_project_icon");

/// The intent options every `project * apply` takes, with the section's own
/// description of the document shape.
fn intentOptions(comptime intent_description: []const u8) [5]spec.OptionSpec {
    return .{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "intent", .kind = .path, .description = intent_description },
        .{ .long = "intent-json", .kind = .string, .description = "The intent itself, instead of a file; the same document the intent option describes" },
        .{ .long = "file", .kind = .path, .description = "Alias for --intent" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };
}

const godot_option = spec.OptionSpec{ .long = "godot", .kind = .path, .description = "Godot binary; default $GODOT, then godot on PATH, then the macOS app bundle" };
const import_options = [_]spec.OptionSpec{
    .{ .long = "project-root", .kind = .path, .description = "Godot project root (default: current directory)" },
    godot_option,
};
const run_options = [_]spec.OptionSpec{
    .{ .long = "project-root", .kind = .path, .description = "Godot project root (default: current directory)" },
    godot_option,
    .{ .long = "scene", .kind = .string, .description = "Scene to run (res:// or project-relative); the main scene when omitted" },
    .{ .long = "frames", .kind = .integer, .description = "Frames to run before quitting; 60 is one second, 5 is enough for a static screen", .default_value = "60" },
    .{ .long = "resolution", .kind = .string, .description = "Window size as WIDTHxHEIGHT; default is the project's display/window/size, else 640x360" },
    .{ .long = "capture-dir", .kind = .path, .description = "Folder under the project for the frame and log; the default is under .godot/, which Godot never imports", .default_value = ".godot/godot-cli" },
    .{ .long = "no-import", .kind = .flag, .description = "Skip the headless import pass that assigns UIDs to new files" },
    .{ .long = "keep-frames", .kind = .flag, .description = "Keep every frame and the .wav; the default keeps only the last frame" },
    .{ .long = "headless", .kind = .flag, .description = "No window and no frames, only the log; for machines without a display" },
    .{ .long = "user-arg", .kind = .string, .description = "Argument passed after --, readable with OS.get_cmdline_user_args(); repeatable", .repeatable = true },
    .{ .long = "press", .kind = .string, .description = "Hold an input action over physics frames, e.g. move_right@10..40 or ui_accept@5; repeatable. Sent as a real InputEventAction and as polled action state, so a focused Control and Input.get_vector both see it", .repeatable = true },
    .{ .long = "click", .kind = .string, .description = "Left-click the centre of a node on a physics frame, e.g. /root/Main/HUD/PauseButton@20; repeatable. A Button's pressed signal fires from this", .repeatable = true },
};

pub fn commands() spec.CommandSpec {
    const project_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
    };

    const intent_apply_options = intentOptions("Intent JSON file: settings {\"<section>\": {\"<key>\": value}}, input {\"actions\": [{\"name\", \"events\": [{\"type\": \"key\", \"keycode\": \"A\", \"physical\": true}]}]}, autoload {\"autoloads\": [{\"name\", \"path\", \"singleton\"}]}, plugins, rendering, physics; see the examples");
    const input_intent_options = intentOptions("Intent JSON file: {\"actions\": [{\"name\": \"move_left\", \"events\": [{\"type\": \"key\", \"keycode\": \"A\", \"physical\": true}, {\"type\": \"joypad_motion\", \"axis\": \"left_x\", \"axis_value\": -1.0}]}]}; each action replaces one of the same name");
    const settings_intent_options = intentOptions("Intent JSON file: {\"<section>\": {\"<key>\": value}}, e.g. {\"application\": {\"run/main_scene\": \"res://scenes/main.tscn\"}, \"display\": {\"window/size/viewport_width\": 640}}; keys merge into the existing file");
    const autoload_intent_options = intentOptions("Intent JSON file: {\"autoloads\": [{\"name\": \"GameState\", \"path\": \"res://scripts/game_state.gd\", \"singleton\": true}], \"replace_all\": false}");
    const plugins_intent_options = intentOptions("Intent JSON file: {\"enable\": [\"my_addon\"], \"disable\": []}; names are folders under addons/");
    const rendering_intent_options = intentOptions("Intent JSON file: {\"method\": \"forward_plus\" | \"mobile\" | \"gl_compatibility\", \"driver\": \"vulkan\" | \"d3d12\" | \"metal\" | \"opengl3\"}, or raw rendering/ keys");
    const physics_intent_options = intentOptions("Intent JSON file: {\"engine_3d\": \"Jolt Physics\", \"gravity_3d\": 980, \"engine_2d\": \"GodotPhysics2D\", \"gravity_2d\": 980}");

    const settings_list_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "section", .kind = .string, .description = "Filter to one section (application, display, layer_names, …)" },
    };

    const settings_get_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "section", .kind = .string, .description = "Section name (e.g. application)", .required = true },
        .{ .long = "key", .kind = .string, .description = "Setting key (e.g. run/main_scene)", .required = true },
    };

    const settings_set_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "section", .kind = .string, .description = "Section name (e.g. application)", .required = true },
        .{ .long = "key", .kind = .string, .description = "Setting key (e.g. run/main_scene)", .required = true },
        .{ .long = "value", .kind = .string, .description = "Plain value (quoted automatically for strings)", .required = true },
        .{ .long = "raw", .kind = .flag, .description = "Store --value verbatim (already Godot-formatted)" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };

    const plugin_toggle_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
        .{ .long = "plugin", .kind = .string, .description = "Plugin path or addon folder name (res://addons/.../plugin.cfg)" },
        .{ .long = "path", .kind = .string, .description = "Alias for --plugin" },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };

    const move_options = [_]spec.OptionSpec{
        .{ .long = "from", .kind = .string, .description = "Current path (res://scripts/player.gd or scripts/player.gd)", .required = true },
        .{ .long = "to", .kind = .string, .description = "New path", .required = true },
        .{ .long = "dry-run", .kind = .flag, .description = "Report what would change without moving or writing" },
    } ++ project_options;

    return .{
        .name = "project",
        .summary = "Read and write Godot project.godot settings",
        .description = "Project-level configuration: input, autoloads, plugins, rendering, physics, display, layer names.",
        .options = &project_options,
        .children = &.{
            .{
                .name = "new",
                .summary = "Create a project.godot in a new or empty folder",
                .description = "Writes the header the project manager writes, config_version=5, and [application] config/name, plus the main scene and window size when given. Refuses to overwrite an existing project.godot; change that with project settings set or project apply.",
                .options = &new_options,
                .handler = newHandler,
            },
            .{
                .name = "import",
                .summary = "Run Godot's headless import so new files get UIDs and .import data",
                .description = "godot --headless --path . --import --quit, from the project root. Run it once after adding scenes, scripts, or textures, before running the game or filling catalog scene_uid fields.",
                .options = &import_options,
                .handler = importHandler,
            },
            .{
                .name = "run",
                .summary = "Run the game for a few frames and capture the last frame and the log",
                .description =
                \\Imports (unless --no-import), then runs the main scene or --scene with --write-movie into capture/, quits after --frames, and reads the log. The result names the last frame, the log and its last 40 lines, and every ERROR or SCRIPT ERROR line with its backtrace; it fails (exit 1) when Godot did not exit cleanly or the log holds an error, so the change is not done until this passes. --press move_right@10..40 holds an input action over a frame range and --click /root/Main/HUD/PauseButton@20 clicks a node, so movement and buttons can be exercised; the frame then shows the result. Frames other than the last, and the .wav Godot writes, are deleted unless --keep-frames. Over MCP the frame is also returned as an image.
                ,
                .options = &run_options,
                .handler = runHandler,
            },
            .{
                .name = "show",
                .summary = "Summarize key project.godot configuration",
                .options = &project_options,
                .handler = showHandler,
            },
            .{
                .name = "move",
                .summary = "Move or rename a file and repoint every reference to it",
                .description = "Renames the file with its .uid and .import sidecars, rewrites every ext_resource path in the project's scenes and resources, repoints catalog manifests, and updates project.godot settings such as the main scene and autoloads. Paths are res:// or project-relative.",
                .options = &move_options,
                .handler = moveHandler,
            },
            .{
                .name = "apply",
                .summary = "Apply unified project intent JSON (input, settings, autoload, plugins, rendering, physics)",
                .description =
                \\One intent with any of the sections: {"settings": {"application": {"run/main_scene": "res://scenes/main.tscn"}}, "input": {"actions": [{"name": "move_left", "events": [{"type": "key", "keycode": "A", "physical": true}]}]}, "autoload": {"autoloads": [{"name": "GameState", "path": "res://scripts/game_state.gd", "singleton": true}]}, "physics": {"engine_3d": "Jolt Physics"}}. Each section takes the same document as the matching project <section> apply command. Give it as a file (--intent) or inline (--intent-json).
                ,
                .options = &intent_apply_options,
                .handler = projectApplyHandler,
            },
            .{
                .name = "input",
                .summary = "Input Map actions in project.godot",
                .children = &.{
                    .{ .name = "list", .summary = "List input actions", .options = &project_options, .handler = inputListHandler },
                    .{ .name = "apply", .summary = "Apply input map intent JSON (merge/replace per action)", .options = &input_intent_options, .handler = inputApplyHandler },
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
                    .{ .name = "apply", .summary = "Apply settings intent JSON (per-key merge)", .options = &settings_intent_options, .handler = settingsApplyHandler },
                    .{ .name = "validate", .summary = "Validate res:// paths in settings", .options = &settings_list_options, .handler = settingsValidateHandler },
                },
            },
            .{
                .name = "autoload",
                .summary = "Autoload singletons in project.godot",
                .children = &.{
                    .{ .name = "list", .summary = "List autoload entries", .options = &project_options, .handler = autoloadListHandler },
                    .{ .name = "apply", .summary = "Apply autoload intent JSON (merge by name; optional replace_all)", .options = &autoload_intent_options, .handler = autoloadApplyHandler },
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
                    .{ .name = "apply", .summary = "Apply plugin intent JSON (enable/disable lists)", .options = &plugins_intent_options, .handler = pluginsApplyHandler },
                    .{ .name = "validate", .summary = "Validate enabled plugin paths exist", .options = &project_options, .handler = pluginsValidateHandler },
                },
            },
            .{
                .name = "rendering",
                .summary = "Rendering method and graphics driver settings",
                .children = &.{
                    .{ .name = "list", .summary = "List [rendering] section settings", .options = &project_options, .handler = renderingListHandler },
                    .{ .name = "apply", .summary = "Apply rendering intent JSON (friendly aliases)", .options = &rendering_intent_options, .handler = renderingApplyHandler },
                    .{ .name = "validate", .summary = "Validate known rendering method/driver values", .options = &project_options, .handler = renderingValidateHandler },
                },
            },
            .{
                .name = "physics",
                .summary = "Physics engine and gravity settings",
                .children = &.{
                    .{ .name = "list", .summary = "List [physics] section settings", .options = &project_options, .handler = physicsListHandler },
                    .{ .name = "apply", .summary = "Apply physics intent JSON (friendly aliases)", .options = &physics_intent_options, .handler = physicsApplyHandler },
                    .{ .name = "validate", .summary = "Validate known physics engine and scalar values", .options = &project_options, .handler = physicsValidateHandler },
                },
            },
        },
    };
}
