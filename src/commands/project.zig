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
const project_export = @import("project_export.zig");
const pos = @import("positionals.zig");

pub fn appFrom(ctx: *anyopaque) *const app_mod.App {
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

pub const IntentSource = struct { label: []const u8, bytes: []const u8 };

/// `--intent-json` carries the document itself; otherwise `--intent` (or the
/// older `--file`) names a file. A missing file reports its path.
pub fn readIntentSource(cli: *const app_mod.App, inv: *const spec.Invocation) !IntentSource {
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

/// Godot's own save of a scene or resource, as the reference `scene
/// compare-godot` checks against. Trial 35 wrote this script by hand and ran
/// Godot from the shell to get one. The copy goes elsewhere, never over the
/// file: letting headless Godot rewrite a scene is what the authoring rules
/// warn against.
fn resaveHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    if (inv.positionals.len == 0) return error.Usage;
    const cli = appFrom(ctx);
    const root = projectRootFrom(inv) orelse ".";
    const source = project_move.normalizeResPath(cli.allocator, root, inv.positionals[0]) catch {
        error_details.record(.{ .field = "file", .value = inv.positionals[0], .hint = "a res:// path or a path inside the project" });
        return error.InvalidPath;
    };
    const output = if (inv.getOption("output")) |out|
        project_move.normalizeResPath(cli.allocator, root, out) catch {
            error_details.record(.{ .field = "output", .value = out, .hint = "a res:// path or a path inside the project" });
            return error.InvalidPath;
        }
    else
        try cli.allocator.print("res://.godot/godot-cli/resave/{s}", .{source["res://".len..]});
    if (std.mem.eql(u8, output, source)) {
        error_details.record(.{ .field = "output", .value = output, .hint = "resave writes a copy to compare against; having headless Godot rewrite the file itself is what the authoring rules warn against. Leave --output out, or give another path" });
        return error.ResaveOverSource;
    }
    const output_fs = try std.fs.path.join(cli.allocator, &.{ root, output["res://".len..] });
    if (std.fs.path.dirname(output_fs)) |dir| std.Io.Dir.cwd().createDirPath(cli.io, dir) catch {};
    std.Io.Dir.cwd().deleteFile(cli.io, output_fs) catch {};

    const godot = try godot_run.locateGodot(cli.allocator, cli.io, cli.environ, inv.getOption("godot"));
    if (!inv.flag("no-import")) {
        const imported = try godot_run.runProcess(cli.allocator, cli.environ, root, &.{ godot, "--headless", "--path", ".", "--import", "--quit" });
        _ = imported;
    }
    const driver_rel = ".godot/godot-cli/resave.gd";
    const driver_fs = try std.fs.path.join(cli.allocator, &.{ root, driver_rel });
    // A scene is built and packed the way EditorNode::_save_scene does it,
    // under the editor hint (--editor with --script runs this as the main
    // loop, with no editor UI and nothing written outside .godot/): edit
    // state, the pre-save notification, pack, and the editor's save flag.
    // Loaded and saved without building, a 3D node's `position` survived
    // where the editor writes `transform`, and properties kept the order
    // they were written in, where the editor writes its class order. From
    // _initialize, not _init, so autoloads exist and scripts naming one
    // compile; otherwise their nodes lost their scripts.
    io_util.writeFileAtomic(cli.io, driver_fs,
        \\extends SceneTree
        \\
        \\# Written by godot-cli project resave: have Godot save a copy of a file the
        \\# way the editor saves it. Safe to delete.
        \\var scene: Node
        \\var holder: SubViewport
        \\var frames := 0
        \\var output := ""
        \\
        \\func _initialize() -> void:
        \\    var args := OS.get_cmdline_user_args()
        \\    output = args[1]
        \\    var build := args.size() < 3 or args[2] != "--no-build"
        \\    var res := ResourceLoader.load(args[0], "", ResourceLoader.CACHE_MODE_IGNORE)
        \\    if res == null:
        \\        print("godot-cli resave: could not load ", args[0])
        \\        quit(1)
        \\        return
        \\    if not (build and res is PackedScene):
        \\        _save(res)
        \\        return
        \\    scene = (res as PackedScene).instantiate(PackedScene.GEN_EDIT_STATE_MAIN)
        \\    if scene == null:
        \\        print("godot-cli resave: could not instantiate ", args[0])
        \\        quit(1)
        \\        return
        \\
        \\# The scene goes into the tree on the first frame rather than from
        \\# _initialize: the root is not in the tree yet there, so the scene would
        \\# enter it later, past the point where it is marked as edited.
        \\func _process(_delta: float) -> bool:
        \\    if scene == null:
        \\        return false
        \\    frames += 1
        \\    if frames == 1:
        \\        _enter()
        \\        return false
        \\    # A few frames, so deferred updates land as they would in the editor
        \\    # before anyone saves: a TabContainer shows its current tab on one.
        \\    if frames < 4:
        \\        return false
        \\    _pack()
        \\    return true
        \\
        \\# As the editor holds it: the edited scene, in a viewport the project's
        \\# size. Out of a tree a Control stores no anchors_preset, and a node not
        \\# marked as edited as it enters takes editor settings (a LineEdit's caret
        \\# blink). Marked as edited while it enters and while it is packed, but not
        \\# across the frames between: a frame with a FogVolume in an edited scene
        \\# crashes this headless editor (Godot's graphics_settings demo did).
        \\func _enter() -> void:
        \\    holder = SubViewport.new()
        \\    holder.size = Vector2i(ProjectSettings.get_setting("display/window/size/viewport_width", 1152), ProjectSettings.get_setting("display/window/size/viewport_height", 648))
        \\    # Nothing here needs drawing.
        \\    holder.render_target_update_mode = SubViewport.UPDATE_DISABLED
        \\    root.add_child(holder)
        \\    edited_scene_root = scene
        \\    holder.add_child(scene)
        \\    edited_scene_root = null
        \\
        \\func _pack() -> void:
        \\    edited_scene_root = scene
        \\    scene.propagate_notification(Node.NOTIFICATION_EDITOR_PRE_SAVE)
        \\    _apply_resets()
        \\    var packed := PackedScene.new()
        \\    var packed_err := packed.pack(scene)
        \\    # Cleared before the scene goes, or the SceneTree names a freed node.
        \\    edited_scene_root = null
        \\    holder.free()
        \\    scene = null
        \\    if packed_err != OK:
        \\        print("godot-cli resave: pack failed, err=", packed_err)
        \\        quit(1)
        \\        return
        \\    _save(packed)
        \\
        \\# The editor plays each mixer's RESET animation before a save when
        \\# reset_on_save is on (EditorNode::_reset_animation_mixers), so the scene
        \\# stores the reset values rather than wherever the last preview left
        \\# them. AnimationMixer.apply_reset is not exposed, so set each track's
        \\# value at time 0 here.
        \\func _apply_resets() -> void:
        \\    for found in scene.find_children("*", "AnimationMixer", true, false):
        \\        var mixer := found as AnimationMixer
        \\        if not mixer.reset_on_save or not mixer.has_animation("RESET"):
        \\            continue
        \\        var anim := mixer.get_animation("RESET")
        \\        var base := mixer.get_node_or_null(mixer.root_node)
        \\        if base == null:
        \\            continue
        \\        for t in anim.get_track_count():
        \\            var path := anim.track_get_path(t)
        \\            var target := base.get_node_or_null(NodePath(path.get_concatenated_names()))
        \\            if target == null or anim.track_get_key_count(t) == 0:
        \\                continue
        \\            var property := path.get_concatenated_subnames()
        \\            match anim.track_get_type(t):
        \\                Animation.TYPE_VALUE:
        \\                    if property != "":
        \\                        target.set_indexed(NodePath(property), anim.value_track_interpolate(t, 0.0))
        \\                Animation.TYPE_BEZIER:
        \\                    if property != "":
        \\                        target.set_indexed(NodePath(property), anim.bezier_track_interpolate(t, 0.0))
        \\                Animation.TYPE_POSITION_3D:
        \\                    if property == "" and target is Node3D:
        \\                        (target as Node3D).position = anim.position_track_interpolate(t, 0.0)
        \\                Animation.TYPE_ROTATION_3D:
        \\                    if property == "" and target is Node3D:
        \\                        (target as Node3D).quaternion = anim.rotation_track_interpolate(t, 0.0)
        \\                Animation.TYPE_SCALE_3D:
        \\                    if property == "" and target is Node3D:
        \\                        (target as Node3D).scale = anim.scale_track_interpolate(t, 0.0)
        \\
        \\func _save(res: Resource) -> void:
        \\    var err := ResourceSaver.save(res, output, ResourceSaver.FLAG_REPLACE_SUBRESOURCE_PATHS)
        \\    print("godot-cli resave: err=", err)
        \\    quit(0 if err == OK else 1)
        \\
    ) catch return error.Io;
    const build = !inv.flag("no-build");
    const outcome = if (build)
        try godot_run.runProcess(cli.allocator, cli.environ, root, &.{ godot, "--headless", "--editor", "--path", ".", "--script", "res://" ++ driver_rel, "--", source, output })
    else
        try godot_run.runProcess(cli.allocator, cli.environ, root, &.{ godot, "--headless", "--path", ".", "--script", "res://" ++ driver_rel, "--", source, output, "--no-build" });
    const code: ?u8 = switch (outcome.term) {
        .exited => |c| c,
        else => null,
    };
    const written = if (std.Io.Dir.cwd().access(cli.io, output_fs, .{})) |_| true else |_| false;
    const ok = code != null and code.? == 0 and written;

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "file", .{ .string = source });
    try data.put(cli.allocator, "output", .{ .string = output });
    try data.put(cli.allocator, "output_path", .{ .string = output_fs });
    try data.put(cli.allocator, "godot", .{ .string = godot });
    try data.put(cli.allocator, "built", .{ .bool = build and std.mem.endsWith(u8, source, ".tscn") });
    if (code) |c| try data.put(cli.allocator, "exit", .{ .integer = c });
    if (!ok) {
        try data.put(cli.allocator, "stdout_tail", .{ .string = tail(outcome.stdout, 1200) });
        try data.put(cli.allocator, "stderr_tail", .{ .string = tail(outcome.stderr, 1200) });
    }
    // Say which check failed: trial 44 got "could not load and save" from a
    // run that had saved and then crashed on its way out.
    const saved_line = std.mem.indexOf(u8, outcome.stdout, "godot-cli resave: err=0") != null;
    const summary = if (ok)
        try cli.allocator.print("Godot saved {s} as {s}; compare with scene compare-godot {s} {s}", .{ source, output, inv.positionals[0], output_fs })
    else if (code == null)
        try cli.allocator.print("Godot {s} {s} and then stopped on a signal rather than exiting; {s}see stdout_tail and stderr_tail", .{ if (saved_line) "saved" else "did not save", source, if (written) "the copy is on disk but may be incomplete; " else "" })
    else if (code.? != 0)
        try cli.allocator.print("Godot exited {d} without saving {s}; see stdout_tail for its reason", .{ code.?, source })
    else
        try cli.allocator.print("Godot exited cleanly but wrote no copy at {s}; see stdout_tail", .{output_fs});
    try data.put(cli.allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .exit_code = if (ok) .success else .failure };
}

pub fn tail(text: []const u8, max: usize) []const u8 {
    return if (text.len > max) text[text.len - max ..] else text;
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

    // Repeatable, so one run can keep frame 0 and a mid-run frame as well as
    // the last: a before-and-after pair in a single run (trial 16).
    var frames_at: std.ArrayList(u32) = .empty;
    for (try inv.getOptionAll(cli.allocator, "frame-at")) |text| {
        try frames_at.append(cli.allocator, std.fmt.parseInt(u32, text, 10) catch return error.InvalidValue);
    }

    // The project's own window size is the right default; a fixed one would
    // silently run a 1280x720 project at 640x360.
    var types: std.ArrayList(godot_run.TypeText) = .empty;
    for (try inv.getOptionAll(cli.allocator, "type")) |text| {
        const entry = godot_run.parseTypeText(text) orelse {
            error_details.record(.{ .field = "type", .value = text, .hint = "write <node-path>@<frame>=<text>, e.g. /root/Main/%Email@10=someone@example.com" });
            return error.InvalidValue;
        };
        try types.append(cli.allocator, entry);
    }
    var focuses: std.ArrayList(godot_run.Focus) = .empty;
    for (try inv.getOptionAll(cli.allocator, "focus")) |text| {
        const entry = godot_run.parseFocus(text) orelse {
            error_details.record(.{ .field = "focus", .value = text, .hint = "write <node-path>@<frame>, e.g. /root/Main/%Email@10" });
            return error.InvalidValue;
        };
        try focuses.append(cli.allocator, entry);
    }

    var main_scene: ?[]const u8 = null;
    var project_resolution: ?[]const u8 = null;
    // A frame means one physics step, so a project that ticks at 30 counts
    // frames at 30 rather than drifting against a fixed 60.
    var physics_fps: u32 = 60;
    if (loadProject(cli, inv)) |loaded_const| {
        var loaded = loaded_const;
        defer loaded.doc.deinit(cli.allocator);
        if (loaded.doc.sectionMut("application")) |app| {
            if (app.getEntry("run/main_scene")) |value| main_scene = try cli.allocator.dupe(u8, project_godot.unquoteValue(value) orelse value);
        }
        if (loaded.doc.sectionMut("display")) |display| {
            if (display.getEntry("window/size/viewport_width")) |w| if (display.getEntry("window/size/viewport_height")) |h| {
                project_resolution = try cli.allocator.print("{s}x{s}", .{ w, h });
            };
        }
        if (loaded.doc.sectionMut("physics")) |physics| {
            if (physics.getEntry("common/physics_ticks_per_second")) |value| {
                physics_fps = std.fmt.parseInt(u32, std.mem.trim(u8, value, " \t"), 10) catch 60;
                if (physics_fps == 0) physics_fps = 60;
            }
        }
    } else |_| {}

    // Godot refuses to run with no scene to run, but only after the import,
    // and the reason was left in the log under a generic checks_failed.
    if (inv.getOption("scene") == null and main_scene == null) {
        error_details.record(.{ .field = "scene", .hint = "the project has no application/run/main_scene; pass --scene res://<scene>.tscn, or set one with project settings set --section application --key run/main_scene --value res://<scene>.tscn" });
        return error.NoMainScene;
    }

    // A 3D scene with no camera captures as the clear colour alone; frame it
    // with a temporary camera instead (trial 37's ask), unless told not to.
    const cameraless = !inv.flag("headless") and godot_run.isCameralessScene3D(cli.allocator, cli.io, root, inv.getOption("scene") orelse main_scene.?);
    const auto_camera = cameraless and !inv.flag("no-auto-camera");

    const run = try godot_run.run(cli.allocator, cli.io, cli.environ, .{
        .project_root = root,
        .godot = inv.getOption("godot"),
        .scene = inv.getOption("scene"),
        .frames = frames,
        .resolution = inv.getOption("resolution") orelse project_resolution orelse godot_run.default_resolution,
        .physics_fps = physics_fps,
        .capture_dir = inv.getOption("capture-dir") orelse godot_run.default_capture_dir,
        .import = !inv.flag("no-import"),
        .keep_frames = inv.flag("keep-frames"),
        .headless = inv.flag("headless"),
        .user_args = user_args,
        .presses = presses.items,
        .clicks = clicks.items,
        .types = types.items,
        .focuses = focuses.items,
        .keep_cursor = inv.flag("keep-cursor"),
        .auto_camera = auto_camera,
        .main_scene = main_scene,
        .frames_at = frames_at.items,
        .log_lines = if (inv.getOption("log-lines")) |text| (std.fmt.parseInt(usize, text, 10) catch return error.InvalidValue) else 40,
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
    if (run.frame_at_paths.len != 0) {
        var kept = std.json.Array.init(cli.allocator);
        for (run.frame_at_paths) |path| try kept.append(.{ .string = path });
        // frame_at stays a single path for the common one-frame case.
        try data.put(cli.allocator, "frame_at", .{ .string = run.frame_at_paths[0] });
        try data.put(cli.allocator, "frames_at", .{ .array = kept });
    }
    if (run.log_tail.len != 0) try data.put(cli.allocator, "log_tail", .{ .string = run.log_tail });

    var messages: std.ArrayList([]const u8) = .empty;
    // A headless run writes no frames, so the layout the click was aimed at
    // is the one thing about it nobody can look at afterwards.
    if (inv.flag("headless") and clicks.items.len != 0) {
        try messages.append(cli.allocator, "clicks under --headless reach the node and fire its signals, since the run puts the project's viewport size back; what a headless run cannot give you is the frame, so the layout the click landed on is unverified. Run with a window when the layout is what is in question");
    }
    // Without this, a run with --keep-cursor and nothing to hover over reads
    // as though the frame is showing a held hover style.
    if (inv.flag("keep-cursor") and clicks.items.len == 0) {
        try messages.append(cli.allocator, "keep-cursor does nothing without --click: the cursor only moves when a click puts it somewhere");
    }

    // The run passes on a grey frame when a 3D scene has no camera; say so,
    // rather than leave the frame to be misread. A headless run has no frame.
    if (cameraless) {
        try data.put(cli.allocator, "no_camera_3d", .{ .bool = true });
        try data.put(cli.allocator, "auto_camera", .{ .bool = auto_camera });
        // The driver says in the log when it also lit the scene.
        const lit = auto_camera and std.mem.indexOf(u8, run.log_tail, "and a temporary light") != null;
        try data.put(cli.allocator, "auto_light", .{ .bool = lit });
        try messages.append(cli.allocator, if (auto_camera)
            "the scene has 3D nodes and no Camera3D, in its own file or in any scene it instances, so the run added a temporary one framing everything visible (and a light, if the scene has none); neither is written to the file. The frame shows the scene, not what a player will see: the game itself has no camera until one is added (the camera_3d recipe places and aims one)"
        else
            "the scene has 3D nodes and no Camera3D, in its own file or in any scene it instances, so unless a script adds one the frame shows only the clear colour: this run shows the scene loads, not how it looks. Add a Camera3D (and a light) to see it, or run without --no-auto-camera");
    }

    const clean_exit = run.exit != null and run.exit.? == 0;
    const ok = clean_exit and run.errors.len == 0;
    // A game that quits itself (a Quit button clicked) writes fewer frames
    // than were asked for; the summary said all of them ran.
    const quit_early = !inv.flag("headless") and run.frames_written > 0 and run.frames_written < frames;
    const summary = if (ok and quit_early)
        try cli.allocator.print("the game quit after {d} of {d} frame(s), with no errors; read {s}", .{ run.frames_written, frames, run.frame orelse run.log_path })
    else if (ok)
        try cli.allocator.print("ran {d} frame(s) with no errors; read {s}", .{ frames, run.frame orelse run.log_path })
    else if (!clean_exit)
        try cli.allocator.print("godot did not exit cleanly (exit {?d}); see {s} and {s}", .{ run.exit, if (run.stderr_tail.len != 0) "stderr_tail" else "log_tail", run.log_path })
    else
        try cli.allocator.print("{d} error line(s) in {s}; the change is not done", .{ run.errors.len, run.log_path });
    try data.put(cli.allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .messages = messages.items, .exit_code = if (ok) .success else .failure };
}

/// "4.8" from "4.8", "4.7.2" or "4.8.beta1.official.4d10419ca".
fn minorVersion(text: []const u8) ?[]const u8 {
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, text, " \t\r\n"), '.');
    const major = parts.next() orelse return null;
    const minor = parts.next() orelse return null;
    _ = std.fmt.parseInt(u32, major, 10) catch return null;
    _ = std.fmt.parseInt(u32, minor, 10) catch return null;
    return text[0 .. major.len + 1 + minor.len];
}

/// The minor version of the Godot on the path (or --godot, or GODOT), read
/// from `godot --version`; null when there is none to ask.
fn detectGodotMinor(cli: *const app_mod.App, inv: *const spec.Invocation) ?[]const u8 {
    const godot = godot_run.locateGodot(cli.allocator, cli.io, cli.environ, inv.getOption("godot")) catch return null;
    const outcome = godot_run.runProcess(cli.allocator, cli.environ, ".", &.{ godot, "--version" }) catch return null;
    const first = std.mem.trim(u8, outcome.stdout[0 .. std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len], " \r");
    return minorVersion(first);
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
    // config/features names the engine version and the renderer, as the
    // project manager writes them; godot-cli reads the version back to pick
    // the input-map layout and the export option table, so a project without
    // it got the newest of each whatever Godot it was made for.
    const renderer = inv.getOption("renderer") orelse "forward_plus";
    const renderer_feature = if (std.mem.eql(u8, renderer, "forward_plus"))
        "Forward Plus"
    else if (std.mem.eql(u8, renderer, "mobile"))
        "Mobile"
    else if (std.mem.eql(u8, renderer, "gl_compatibility"))
        "GL Compatibility"
    else {
        error_details.record(.{ .field = "renderer", .value = renderer, .hint = "forward_plus, mobile or gl_compatibility" });
        return error.InvalidValue;
    };
    var version_note: ?[]const u8 = null;
    const godot_minor: ?[]const u8 = if (inv.getOption("godot-version")) |given| blk: {
        const minor = minorVersion(given) orelse {
            error_details.record(.{ .field = "godot-version", .value = given, .hint = "a Godot version such as 4.8 or 4.7.2" });
            return error.InvalidValue;
        };
        break :blk minor;
    } else detectGodotMinor(cli, inv) orelse blk: {
        version_note = "no Godot was found to read its version from, so config/features is left out and godot-cli treats the project as the newest Godot it knows; pass --godot-version 4.7 (or set GODOT) to name it";
        break :blk null;
    };
    if (godot_minor) |minor| {
        // Godot sorts the list: "4.8" before "Forward Plus".
        try w.print("config/features=PackedStringArray(\"{s}\", \"{s}\")\n", .{ minor, renderer_feature });
    }
    if (!inv.flag("no-icon")) try w.writeAll("config/icon=\"res://icon.svg\"\n");
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

    if (!std.mem.eql(u8, renderer, "forward_plus")) {
        try w.print("\n[rendering]\n\nrenderer/rendering_method=\"{s}\"\n", .{renderer});
        if (std.mem.eql(u8, renderer, "gl_compatibility")) try w.writeAll("renderer/rendering_method.mobile=\"gl_compatibility\"\n");
    }

    var doc = try project_godot.parseBytes(cli.allocator, text.written());
    defer doc.deinit(cli.allocator);

    var wrote_icon = false;
    var messages: std.ArrayList([]const u8) = .empty;
    if (version_note) |note| try messages.append(cli.allocator, note);
    var vcs_written: std.ArrayList([]const u8) = .empty;
    if (!inv.flag("no-vcs")) {
        // What the project manager writes when "Version Control Metadata" is
        // left at Git (EditorVCSInterface::create_vcs_metadata_files). Godot
        // overwrites; this keeps a file that is already there.
        const vcs_files = [_]struct { name: []const u8, text: []const u8 }{
            .{ .name = ".gitignore", .text = "# Godot 4+ specific ignores\n.godot/\n/android/\n" },
            .{ .name = ".gitattributes", .text = "# Normalize EOL for all files that Git considers text files.\n* text=auto eol=lf\n" },
        };
        for (vcs_files) |file| {
            const file_path = try std.fs.path.join(cli.allocator, &.{ root, file.name });
            if (std.Io.Dir.cwd().access(cli.io, file_path, .{})) |_| continue else |_| {}
            if (!inv.flag("dry-run")) {
                std.Io.Dir.cwd().createDirPath(cli.io, root) catch {};
                io_util.writeFileAtomic(cli.io, file_path, file.text) catch return error.Io;
            }
            try vcs_written.append(cli.allocator, file.name);
        }
        const gitignore_kept = for (vcs_written.items) |written| {
            if (std.mem.eql(u8, written, ".gitignore")) break false;
        } else true;
        if (gitignore_kept and !try project_export.gitignoresGodotDir(cli, root)) {
            try messages.append(cli.allocator, "the .gitignore already here does not ignore .godot/: add a .godot/ line, or a git add of the whole project commits Godot's caches and any export secrets in .godot/export_credentials.cfg");
        }
    }
    if (!inv.flag("dry-run")) {
        std.Io.Dir.cwd().createDirPath(cli.io, root) catch {};
        try project_godot.writeFile(cli.allocator, cli.io, path, &doc);
    }
    // The project manager drops icon.svg beside project.godot, and the
    // examples reference res://icon.svg; write it unless one exists. A dry
    // run reports it as it reports the other files (trial 43).
    if (!inv.flag("no-icon")) {
        const icon_path = try std.fs.path.join(cli.allocator, &.{ root, "icon.svg" });
        if (std.Io.Dir.cwd().access(cli.io, icon_path, .{})) |_| {} else |_| {
            if (!inv.flag("dry-run")) io_util.writeFileAtomic(cli.io, icon_path, default_icon_svg) catch return error.Io;
            wrote_icon = true;
        }
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = path });
    try data.put(cli.allocator, "name", .{ .string = name });
    if (inv.getOption("main-scene")) |main_scene| try data.put(cli.allocator, "main_scene", .{ .string = main_scene });
    try data.put(cli.allocator, "icon_written", .{ .bool = wrote_icon });
    try data.put(cli.allocator, "godot_version", if (godot_minor) |minor| .{ .string = minor } else .null);
    try data.put(cli.allocator, "renderer", .{ .string = renderer });
    var vcs_array: std.json.Array = .init(cli.allocator);
    for (vcs_written.items) |file| try vcs_array.append(.{ .string = file });
    try data.put(cli.allocator, "vcs_files_written", .{ .array = vcs_array });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    var also: std.ArrayList([]const u8) = .empty;
    if (wrote_icon) try also.append(cli.allocator, "icon.svg");
    try also.appendSlice(cli.allocator, vcs_written.items);
    const also_text = try std.mem.join(cli.allocator, ", ", also.items);
    try data.put(cli.allocator, "summary", .{ .string = try cli.allocator.print("{s} {s}{s}{s}", .{ if (inv.flag("dry-run")) "would create" else "created", path, if (also.items.len > 0) " with " else "", also_text }) });
    return .{ .data = .{ .object = data }, .messages = messages.items };
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
        var events = std.json.Array.init(cli.allocator);
        for (action.events) |event| try events.append(.{ .string = event });
        try row.put(cli.allocator, "events", .{ .array = events });
        try arr.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "actions", .{ .array = arr });
    try data.put(cli.allocator, "action_count", .{ .integer = @intCast(actions.len) });
    const summary = try cli.allocator.print("listed {d} input action(s)", .{actions.len});
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
    // Each applied action read back from what will be written, its events in
    // words, so the binding can be checked against the intent.
    var actions = std.json.Array.init(cli.allocator);
    const input_section = loaded.doc.sectionMut("input");
    for (applied.applied_actions) |name| {
        try names.append(.{ .string = try cli.allocator.dupe(u8, name) });
        var row: std.json.ObjectMap = .{};
        try row.put(cli.allocator, "name", .{ .string = try cli.allocator.dupe(u8, name) });
        var events = std.json.Array.init(cli.allocator);
        if (input_section) |section| if (section.getEntry(name)) |value| {
            for (try project_input.describeEvents(cli.allocator, value)) |event| try events.append(.{ .string = event });
        };
        try row.put(cli.allocator, "events", .{ .array = events });
        try actions.append(.{ .object = row });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, loaded.path) });
    try data.put(cli.allocator, "intent", .{ .string = try cli.allocator.dupe(u8, intent_path) });
    try data.put(cli.allocator, "applied_actions", .{ .array = names });
    try data.put(cli.allocator, "actions", .{ .array = actions });
    try data.put(cli.allocator, "added_count", .{ .integer = @intCast(applied.added_count) });
    try data.put(cli.allocator, "replaced_count", .{ .integer = @intCast(applied.replaced_count) });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    const summary = try cli.allocator.print(
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
    const summary = try cli.allocator.print("input map: {d} issue(s)", .{issue_count});
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
    const summary = try cli.allocator.print("listed {d} setting(s)", .{settings.len});
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
        try cli.allocator.print("{s}/{s} = {s}", .{ section, key, text })
    else
        try cli.allocator.print("{s}/{s} not found", .{ section, key });
    try data.put(cli.allocator, "summary", .{ .string = summary });

    return .{ .data = .{ .object = data }, .messages = &.{} };
}

/// Whether `text` already reads as a Godot value other than a bare word:
/// a number, a bool, a quoted string, or a constructor Godot knows.
fn isVariantText(allocator: std.mem.Allocator, text: []const u8) bool {
    const variant = @import("../godot/variant/root.zig");
    const parsed = variant.parsePropertyValue(allocator, text) catch return false;
    return switch (parsed.kind) {
        .raw, .null => false,
        else => true,
    };
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
    } else if (isVariantText(cli.allocator, value_text)) blk: {
        // A number, true/false, or Godot's own text for a value
        // (Vector2i(640, 360), PackedStringArray("4.8", "Mobile")) goes in
        // as it is; quoting it stored the string "640" where Godot wants the
        // integer, and a quoted PackedStringArray that Godot reads as text.
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
    const summary = try cli.allocator.print("set {s}/{s}", .{ section, key });
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
    const summary = try cli.allocator.print(
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
    const summary = try cli.allocator.print("project settings: {d} issue(s)", .{issue_count});
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
    const summary = try cli.allocator.print("listed {d} autoload(s)", .{autoloads.len});
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
    const summary = try cli.allocator.print(
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
    const summary = try cli.allocator.print("autoloads: {d} issue(s)", .{issue_count});
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
    const summary = try cli.allocator.print("listed {d} plugin(s)", .{plugins.len});
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
    const summary = try cli.allocator.print(
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
    const summary = try cli.allocator.print("editor plugins: {d} issue(s)", .{issue_count});
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
    const summary = try cli.allocator.print("listed {d} rendering setting(s)", .{settings.len});
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
    const summary = try cli.allocator.print(
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
    const summary = try cli.allocator.print("rendering: {d} issue(s)", .{issue_count});
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

    var result = try project_move.moveResource(cli.allocator, cli.io, root, from, to, inv.flag("dry-run"), inv.flag("rename-ids"));
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
    if (inv.flag("rename-ids")) try data.put(cli.allocator, "ids_renamed", .{ .integer = @intCast(result.ids_renamed) });
    try data.put(cli.allocator, "changed_files", .{ .array = files });
    try data.put(cli.allocator, "dry_run", .{ .bool = inv.flag("dry-run") });
    // Godot's uid cache still maps the old path, so validation reports
    // uid_path_mismatch until an import refreshes it. --import runs that here,
    // which is what makes "validate after every edit" hold for a move.
    var imported = false;
    if (!inv.flag("dry-run")) {
        if (inv.flag("import")) {
            const godot = try godot_run.locateGodot(cli.allocator, cli.io, cli.environ, inv.getOption("godot"));
            const outcome = try godot_run.runProcess(cli.allocator, cli.environ, root, &.{ godot, "--headless", "--path", ".", "--import", "--quit" });
            imported = switch (outcome.term) {
                .exited => |code| code == 0,
                else => false,
            };
            try data.put(cli.allocator, "imported", .{ .bool = imported });
        }
        if (!imported) {
            try data.put(cli.allocator, "note", .{ .string = "Godot's uid_cache.bin still maps the old path until the next import; scene validate reports uid_path_mismatch until project import (or project run) has run. Pass --import to do it here" });
        }
    }
    const summary = try cli.allocator.print("moved {s} to {s}; retargeted {d} reference(s) in {d} file(s), {d} manifest(s), {d} setting(s)", .{ result.from, result.to, result.references_retargeted, result.files_changed, result.manifests_updated, result.settings_updated });
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

    const text = try cli.allocator.print(
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
    const summary = try cli.allocator.print("applied {d} project section(s)", .{applied.sections.len});
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
    const summary = try cli.allocator.print("listed {d} physics setting(s)", .{settings.len});
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
    const summary = try cli.allocator.print("applied {d} physics setting(s)", .{applied.applied_keys.len});
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
    const summary = try cli.allocator.print("physics: {d} issue(s)", .{issue_count});
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
    .{ .long = "godot-version", .kind = .string, .description = "The Godot version the project is for (4.8, 4.7), written into config/features; default the version of the Godot on the path" },
    .{ .long = "renderer", .kind = .string, .description = "forward_plus (the default), mobile or gl_compatibility, as the project manager offers" },
    godot_option,
    .{ .long = "no-vcs", .kind = .flag, .description = "Do not write the .gitignore (ignoring .godot/ and /android/) and .gitattributes the project manager writes" },
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
        .{ .long = "file", .kind = .path, .description = "Alias for --intent", .advanced = true },
        .{ .long = "dry-run", .kind = .flag, .description = "Apply in memory without writing project.godot" },
    };
}

pub const godot_option = spec.OptionSpec{ .long = "godot", .kind = .path, .description = "Godot binary; default $GODOT, then godot on PATH, then the macOS app bundle" };
const import_options = [_]spec.OptionSpec{
    .{ .long = "project-root", .kind = .path, .description = "Godot project root (default: current directory)" },
    godot_option,
};
const resave_options = [_]spec.OptionSpec{
    .{ .long = "project-root", .kind = .path, .description = "Godot project root (default: current directory)" },
    godot_option,
    .{ .long = "output", .kind = .string, .description = "Where the copy goes, res:// or project-relative; default .godot/godot-cli/resave/<the file's path>, where Godot imports nothing" },
    .{ .long = "no-import", .kind = .flag, .description = "Skip the import that runs first; a project never imported cannot load its textures" },
    .{ .long = "no-build", .kind = .flag, .description = "Load and save the file as it is, without building the scene first: what Godot writes for the file's own content, not what the editor would store" },
};
const run_options = [_]spec.OptionSpec{
    .{ .long = "project-root", .kind = .path, .description = "Godot project root (default: current directory)" },
    godot_option,
    .{ .long = "scene", .kind = .string, .description = "Scene to run (res:// or project-relative); the main scene when omitted" },
    .{ .long = "frames", .kind = .integer, .description = "Frames to run before quitting; 60 is one second, 5 is enough for a static screen", .default_value = "60" },
    .{ .long = "resolution", .kind = .string, .description = "Window size as WIDTHxHEIGHT; default is the project's display/window/size, else Godot's own 1152x648" },
    .{ .long = "capture-dir", .kind = .path, .description = "Folder under the project for the frame and log; the default is under .godot/, which Godot never imports", .default_value = ".godot/godot-cli" },
    .{ .long = "no-import", .kind = .flag, .description = "Skip the headless import pass that assigns UIDs to new files" },
    .{ .long = "keep-frames", .kind = .flag, .description = "Keep every frame and the .wav; the default keeps only the last frame" },
    .{ .long = "headless", .kind = .flag, .description = "No window and no frames, only the log; for machines without a display. --press and --click both work: the run puts the project's viewport size back, which the headless display server does not report. What you lose is the frame" },
    .{ .long = "user-arg", .kind = .string, .description = "Argument passed after --, readable with OS.get_cmdline_user_args(); repeatable", .repeatable = true },
    .{ .long = "press", .kind = .string, .description = "Hold an input action over a frame range, e.g. move_right@10..40 or ui_accept@5; repeatable. Sent as a real InputEventAction and as polled action state, so a focused Control and Input.get_vector both see it. It is the action itself, not a key or button bound to it, so it proves code reacting to the action, not the bindings; project input list reports those", .repeatable = true },
    .{ .long = "click", .kind = .string, .description = "Left-click the centre of a node on a frame, e.g. /root/Main/HUD/PauseButton@20; repeatable. A Button's pressed signal fires from this, and the cursor moves off the node after the release so later frames show its normal style. Works under --headless too. A click on a node laid out beyond the viewport reaches nothing and fails the run rather than passing silently", .repeatable = true },
    .{ .long = "type", .kind = .string, .description = "Type text into a LineEdit or TextEdit on a frame: <node-path>@<frame>=<text>, e.g. /root/Main/%Email@20=someone@example.com; repeatable. The field is focused and emptied, then the text goes in as real key events, so text_changed fires the way a validating form expects. The value lands the frame after, so click Submit at least two frames later", .repeatable = true },
    .{ .long = "focus", .kind = .string, .description = "Give a Control keyboard focus on a frame: <node-path>@<frame>; repeatable. --type focuses the field it types into, so this is for watching a focus ring or a tab order", .repeatable = true },
    .{ .long = "no-auto-camera", .kind = .flag, .description = "For a 3D scene with no Camera3D, capture what the game would show (the clear colour) instead of adding a temporary camera that frames the scene" },
    .{ .long = "keep-cursor", .kind = .flag, .description = "Leave the synthetic cursor on the last clicked node instead of moving it off, so the frame shows that node's hover style; only the in-game cursor moves either way, never the desktop pointer" },
    .{ .long = "frame-at", .kind = .integer, .description = "Also keep this frame (numbered from 0) and return it as frame_at; repeatable, so --frame-at 0 --frame-at 30 keeps a before-and-after pair as well as the last frame", .repeatable = true },
    .{ .long = "log-lines", .kind = .integer, .description = "Lines of the log to return inline as log_tail", .default_value = "40" },
};

pub fn commands() spec.CommandSpec {
    const project_options = [_]spec.OptionSpec{
        .{ .long = "project-root", .kind = .path, .description = "Godot project root (directory containing project.godot)" },
    };

    const intent_apply_options = intentOptions("Intent JSON file: settings {\"<section>\": {\"<key>\": value}}, input {\"actions\": [{\"name\", \"events\": [{\"type\": \"key\", \"keycode\": \"A\", \"physical\": true}]}]}, autoload {\"autoloads\": [{\"name\", \"path\", \"singleton\"}]}, plugins, rendering, physics; see the examples");
    const input_intent_options = intentOptions("Intent JSON file: {\"actions\": [{\"name\": \"move_left\", \"deadzone\": 0.5, \"events\": [{\"type\": \"key\", \"keycode\": \"A\", \"physical\": true}, {\"type\": \"joypad_motion\", \"axis\": \"left_x\", \"axis_value\": -1.0}]}]}; each action replaces one of the same name, and deadzone is optional (Godot defaults to 0.5)");
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
        .{ .long = "value", .kind = .string, .description = "The value: a number, true or false, or Godot's own text for a value (Vector2i(640, 360), PackedStringArray(\"4.8\", \"Mobile\")) is written as it is, and anything else is quoted as a string (res://scenes/main.tscn)", .required = true },
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
        .{ .long = "rename-ids", .kind = .flag, .description = "Re-seed ext_resource ids from the new file name, so a Script_player id stops naming a file called hero.gd; ids already in use are left alone" },
        godot_option,
        .{ .long = "import", .kind = .flag, .description = "Run Godot's headless import after the move, so its uid cache stops mapping the old path and validation stops reporting uid_path_mismatch" },
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
                .description = "Writes the header the project manager writes, config_version=5, and [application] config/name, config/features (the Godot version, from --godot-version or the Godot on the path, and the renderer) and config/icon, plus the main scene and window size when given. Like the project manager, it also writes icon.svg, a .gitignore holding .godot/ and /android/ (.godot/ is Godot's cache, and where export secrets go), and a .gitattributes normalizing line endings, keeping any that already exist (--no-icon, --no-vcs to skip them). Refuses to overwrite an existing project.godot; change that with project settings set or project apply. Result data: path, name, main_scene, icon_written, godot_version, renderer, vcs_files_written, dry_run, summary.",
                .options = &new_options,
                .handler = newHandler,
            },
            .{
                .name = "import",
                .summary = "Run Godot's headless import so new files get UIDs and .import data",
                .description = "godot --headless --path . --import --quit, from the project root. Run it once after adding scenes, scripts, or textures, before running the game or filling catalog scene_uid fields. Godot writes into the project as it imports: a .import file beside each asset, a .uid file beside each script, and the .godot/ folder, which holds the uid cache. Commit the .import and .uid files: a UID is assigned once and kept there, and if the file changes later, a checkout without them would be assigned a different one.",
                .options = &import_options,
                .handler = importHandler,
            },
            .{
                .name = "resave",
                .summary = "Have Godot save a copy of a scene the way the editor would, the reference for compare-godot",
                .description = "Imports (unless --no-import), then has Godot save a copy to --output, by default .godot/godot-cli/resave/<its path>, where Godot imports nothing. Never over the file itself. A scene is built first, as the editor builds the scene it saves: Godot runs headless with the editor hint, instantiates the scene in edit state as the edited scene, in a viewport the project's size, lets a few frames run, sends the pre-save notification, packs it and saves it with the editor's flags. So the copy holds what the editor would store: a 3D node's position comes back as transform, properties in the editor's order, editor-only lines such as anchors_preset kept. An AnimationPlayer or AnimationTree with reset_on_save has its RESET animation applied first, as the editor does. --no-build loads and saves the file as it is instead. scene compare-godot <file> <copy> checks the file against the copy. That check is semantic, not byte for byte: saved to a new path, the copy's ext_resource ids are renumbered and its uids left out, so compare-godot leaves those out and lists them in skipped. Nothing outside .godot/ is written. The driver script it runs is .godot/godot-cli/resave.gd. Result data: file, output, output_path, built, exit, summary.",
                .options = &resave_options,
                .handler = resaveHandler,
                .positionals = &pos.file,
            },
            .{
                .name = "run",
                .summary = "Run the game for a few frames and capture the last frame and the log",
                .description =
                \\Imports (unless --no-import; the import writes .import and .uid files into the project, as project import says), then runs the main scene or --scene with --write-movie into the capture folder (--capture-dir, under .godot/ by default, which Godot never imports), quits after --frames, and reads the log. The result names the last frame, the log and its last 40 lines, and every ERROR or SCRIPT ERROR line with its backtrace; it fails (exit 1) when Godot did not exit cleanly or the log holds an error, so the change is not done until this passes. A run can pass with a wrong layout, so read the frame as well as the log. --press move_right@10..40 holds an input action over a frame range and --click /root/Main/HUD/PauseButton@20 clicks a node, so movement and buttons can be exercised; the frame then shows the result. The cursor moves off the node after a click, so the last frame shows its normal style; --keep-cursor leaves it there for the hover style. Only the game's own cursor moves, never the desktop pointer. Result data: frame (path of the last PNG), log, log_tail (last 40 lines), errors and error_count, exit and import_exit, stderr_tail, frames_written, presses, clicks, duration_ms, summary. Frames other than the last, and the .wav Godot writes, are deleted unless --keep-frames. Over MCP the frame is also returned as an image.
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
                    .{ .name = "list", .summary = "List input actions", .description = "Each action's name, deadzone, event_count, and events: each binding as one line in the apply intent's words, such as \"A (physical)\", \"Ctrl+S (physical)\", \"mouse left\", \"joypad start\" or \"joypad left_x -1.0\", with \"(device N)\" when it is pinned to one device. Result data: path, actions, action_count, summary.", .options = &project_options, .handler = inputListHandler },
                    .{
                        .name = "apply",
                        .summary = "Apply input map intent JSON (merge/replace per action)",
                        .description = "One intent: {\"actions\": [{\"name\": \"move_left\", \"deadzone\": 0.5, \"events\": [...]}]}; each action replaces the one of the same name. Event types: {\"type\": \"key\", \"keycode\": <name or number>, \"physical\": true, \"ctrl\": false, \"shift\": false, \"alt\": false, \"meta\": false} (physical defaults to true: the key's place on the keyboard, so WASD stays put on AZERTY), {\"type\": \"mouse_button\", \"button\": <name or number>}, {\"type\": \"joypad_button\", \"button\": <name or number>}, {\"type\": \"joypad_motion\", \"axis\": <name or number>, \"axis_value\": -1.0}. Keys: " ++ project_input.key_names ++ ". Mouse buttons: " ++ project_input.mouse_button_names ++ ". Joypad buttons: " ++ project_input.joypad_button_names ++ ". Joypad axes: " ++ project_input.joypad_axis_names ++ ". Result data: path, intent, applied_actions, actions (each applied action's events in words, as input list gives them, on a dry run too, so the bindings can be checked before anything is written), added_count, replaced_count, dry_run, summary. To check a change that touches only the input map: project input validate, then project run with --press <action>@<frames> on any scene that reacts to the action (--scene res://... when the project has no main scene), and read the log.",
                        .options = &input_intent_options,
                        .handler = inputApplyHandler,
                    },
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
            project_export.commands(),
        },
    };
}
