//! Run the Godot editor binary against a project: import, then a short run
//! that writes frames and a log into a `.gdignore`d capture folder.
//!
//! This is the loop the agent docs describe by hand (`godot --headless
//! --import --quit`, then `--write-movie ... --quit-after N --log-file ...`),
//! packaged so a client without a shell can run it and read one result:
//! the last frame, the log path, and the error lines pulled out of the log.

const std = @import("std");

pub const Options = struct {
    project_root: []const u8,
    /// Godot binary; found when null (see `locateGodot`).
    godot: ?[]const u8 = null,
    /// Scene to run, res:// or project-relative; the main scene when null.
    scene: ?[]const u8 = null,
    frames: u32 = 60,
    resolution: []const u8 = "640x360",
    /// The project's `physics/common/physics_ticks_per_second`. Passed to
    /// Godot as `--fixed-fps`, which makes one main-loop iteration advance
    /// exactly one physics step, so `frames` counts the same thing whether
    /// it is read as a frame written, a physics frame, or a click's `@n`.
    /// Without it Godot paces physics off the wall clock while `--quit-after`
    /// counts iterations, and the two drift apart by whatever the machine
    /// happened to be doing.
    physics_fps: u32 = 60,
    /// Relative to the project root. The default sits under `.godot/`, which
    /// Godot never imports and projects already ignore.
    capture_dir: []const u8 = default_capture_dir,
    import: bool = true,
    /// Keep every frame; the default keeps only the last and drops the .wav.
    keep_frames: bool = false,
    /// No window and no frames, only the log. For machines without a display.
    headless: bool = false,
    /// Passed after `--`; reachable from OS.get_cmdline_user_args().
    user_args: []const []const u8 = &.{},
    /// Input actions to hold for a range of frames. When any are
    /// given the run goes through a generated SceneTree script that loads the
    /// scene and drives Input.action_press/release, so movement and buttons
    /// can be exercised without a hand-written test path.
    presses: []const Press = &.{},
    /// The main scene from project.godot, needed by the press script when
    /// `scene` is null. Resolved by the caller.
    main_scene: ?[]const u8 = null,
    /// Mouse clicks on a node, by viewport path, on a frame.
    clicks: []const Click = &.{},
    /// Text typed into a LineEdit or TextEdit, by viewport path, on a frame.
    types: []const TypeText = &.{},
    /// Keyboard focus moved to a node, by viewport path, on a frame.
    focuses: []const Focus = &.{},
    /// Leave the synthetic cursor on the node after a click, so the frame
    /// shows its hover style. By default the cursor is moved off-screen after
    /// the release and the node draws normally again.
    keep_cursor: bool = false,
    /// Also keep these frames (as Godot numbers them, from 0): frame 0 for a
    /// before-and-after pair, a mid-run number for a state such as a menu
    /// part-way open.
    frames_at: []const u32 = &.{},
    /// Lines of the log to return inline.
    log_lines: usize = 40,
};

pub const Click = struct {
    node_path: []const u8,
    frame: u32,
};

/// `/root/Main/HUD/PauseButton@20`: left-click the centre of that node on
/// frame 20 (press) and release on the next.
pub fn parseClick(text: []const u8) ?Click {
    const at = std.mem.lastIndexOfScalar(u8, text, '@') orelse return null;
    if (at == 0) return null;
    const frame = std.fmt.parseInt(u32, text[at + 1 ..], 10) catch return null;
    if (frame == 0) return null;
    return .{ .node_path = text[0..at], .frame = frame };
}

pub const TypeText = struct {
    node_path: []const u8,
    frame: u32,
    text: []const u8,
};

/// `/root/Main/%Email@10=someone@example.com`: focus that node on frame 10 and
/// type the text into it.
///
/// The frame is read from between the last `@` and the first `=`, so both an
/// address in the text and an `=` in a password survive.
pub fn parseTypeText(text: []const u8) ?TypeText {
    const equals = std.mem.indexOfScalar(u8, text, '=') orelse return null;
    const target = text[0..equals];
    const at = std.mem.lastIndexOfScalar(u8, target, '@') orelse return null;
    if (at == 0) return null;
    const frame = std.fmt.parseInt(u32, target[at + 1 ..], 10) catch return null;
    if (frame == 0) return null;
    return .{ .node_path = target[0..at], .frame = frame, .text = text[equals + 1 ..] };
}

pub const Focus = struct {
    node_path: []const u8,
    frame: u32,
};

/// `/root/Main/%Email@10`: give that node keyboard focus on frame 10.
pub fn parseFocus(text: []const u8) ?Focus {
    const click = parseClick(text) orelse return null;
    return .{ .node_path = click.node_path, .frame = click.frame };
}

pub const Press = struct {
    action: []const u8,
    /// First frame (1-based) the action is held on.
    start: u32,
    /// Last frame the action is held on, inclusive.
    end: u32,
};

/// `name@10..40` holds an action over a frame range; `name@10` presses it
/// on one frame.
pub fn parsePress(text: []const u8) ?Press {
    const at = std.mem.indexOfScalar(u8, text, '@') orelse return null;
    const action = text[0..at];
    if (action.len == 0) return null;
    const range = text[at + 1 ..];
    if (std.mem.indexOf(u8, range, "..")) |dots| {
        const start = std.fmt.parseInt(u32, range[0..dots], 10) catch return null;
        const end = std.fmt.parseInt(u32, range[dots + 2 ..], 10) catch return null;
        if (end < start or start == 0) return null;
        return .{ .action = action, .start = start, .end = end };
    }
    const frame = std.fmt.parseInt(u32, range, 10) catch return null;
    if (frame == 0) return null;
    return .{ .action = action, .start = frame, .end = frame };
}

pub const Result = struct {
    godot: []const u8,
    import_exit: ?u8 = null,
    exit: ?u8 = null,
    signal: ?[]const u8 = null,
    frame: ?[]const u8 = null,
    frames_written: usize = 0,
    log_path: []const u8,
    /// The last lines of the log, so a client need not read the file.
    log_tail: []const u8 = "",
    errors: []const []const u8,
    stderr_tail: []const u8,
    duration_ms: i64,
    /// Path of the generated press script, when one was used.
    driver_script: ?[]const u8 = null,
    /// Paths of the frames kept for `frames_at`, in the order asked for.
    frame_at_paths: []const []const u8 = &.{},
};

pub const Error = error{
    GodotNotFound,
    OutOfMemory,
    Io,
    SpawnFailed,
};

const macos_default = "/Applications/Godot.app/Contents/MacOS/Godot";
pub const default_capture_dir = ".godot/godot-cli";

/// The binary: an explicit path, then `$GODOT`, then `godot` on `$PATH`,
/// then the macOS app bundle.
pub fn locateGodot(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, explicit: ?[]const u8) Error![]const u8 {
    if (explicit) |path| return allocator.dupe(u8, path) catch return error.OutOfMemory;
    if (environ.getAlloc(allocator, "GODOT")) |value| {
        if (value.len != 0) return value;
    } else |_| {}
    if (environ.getAlloc(allocator, "PATH")) |path_list| {
        var it = std.mem.splitScalar(u8, path_list, std.fs.path.delimiter);
        while (it.next()) |dir| {
            if (dir.len == 0) continue;
            const candidate = std.fs.path.join(allocator, &.{ dir, "godot" }) catch return error.OutOfMemory;
            if (std.Io.Dir.cwd().access(io, candidate, .{})) |_| return candidate else |_| {}
        }
    } else |_| {}
    if (std.Io.Dir.cwd().access(io, macos_default, .{})) |_| {
        return allocator.dupe(u8, macos_default) catch return error.OutOfMemory;
    } else |_| {}
    return error.GodotNotFound;
}

fn ensureCaptureDir(allocator: std.mem.Allocator, io: std.Io, root: []const u8, capture_dir: []const u8) Error!void {
    const dir_path = std.fs.path.join(allocator, &.{ root, capture_dir }) catch return error.OutOfMemory;
    std.Io.Dir.cwd().createDirPath(io, dir_path) catch return error.Io;
    const ignore_path = std.fs.path.join(allocator, &.{ dir_path, ".gdignore" }) catch return error.OutOfMemory;
    if (std.Io.Dir.cwd().access(io, ignore_path, .{})) |_| {} else |_| {
        const file = std.Io.Dir.cwd().createFile(io, ignore_path, .{}) catch return error.Io;
        file.close(io);
    }
}

/// Spawn a child and collect its output. The CLI's Io is the single-threaded
/// global, whose allocator is `.failing`, so spawning through it fails with
/// OutOfMemory; a threaded Io with a real allocator is made for the call.
pub fn runProcess(allocator: std.mem.Allocator, environ: std.process.Environ, root: []const u8, argv: []const []const u8) Error!std.process.RunResult {
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{ .environ = environ });
    defer threaded.deinit();
    const spawn_io = threaded.io();
    return std.process.run(allocator, spawn_io, .{
        .argv = argv,
        .cwd = .{ .path = root },
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.SpawnFailed,
    };
}

fn runGodot(allocator: std.mem.Allocator, environ: std.process.Environ, root: []const u8, argv: []const []const u8) Error!std.process.RunResult {
    return runProcess(allocator, environ, root, argv);
}

fn exitCode(term: std.process.Child.Term) ?u8 {
    return switch (term) {
        .exited => |code| code,
        else => null,
    };
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, options: Options) Error!Result {
    const started = std.Io.Clock.Timestamp.now(io, .real);
    const godot = try locateGodot(allocator, io, environ, options.godot);
    try ensureCaptureDir(allocator, io, options.project_root, options.capture_dir);

    var result = Result{
        .godot = godot,
        .log_path = std.fs.path.join(allocator, &.{ options.project_root, options.capture_dir, "godot.log" }) catch return error.OutOfMemory,
        .errors = &.{},
        .stderr_tail = "",
        .duration_ms = 0,
    };

    // Frames from an earlier run would otherwise be counted and could be
    // picked as the "last" frame when this run writes fewer.
    if (!options.headless) try clearCapture(allocator, io, options);

    if (options.import) {
        const import_run = try runGodot(allocator, environ, options.project_root, &.{ godot, "--headless", "--path", ".", "--import", "--quit" });
        result.import_exit = exitCode(import_run.term);
    }

    // Frame and log paths are relative to the project, and Godot runs with the
    // project as its working directory, so both forms resolve the same way.
    const shot_pattern = std.fmt.allocPrint(allocator, "{s}/shot.png", .{options.capture_dir}) catch return error.OutOfMemory;
    const log_relative = std.fmt.allocPrint(allocator, "{s}/godot.log", .{options.capture_dir}) catch return error.OutOfMemory;
    const frames_text = std.fmt.allocPrint(allocator, "{d}", .{options.frames}) catch return error.OutOfMemory;

    var script_relative: ?[]const u8 = null;
    if (options.presses.len != 0 or options.clicks.len != 0 or options.types.len != 0 or options.focuses.len != 0) {
        script_relative = try writeDriverScript(allocator, io, options);
        result.driver_script = std.fs.path.join(allocator, &.{ options.project_root, script_relative.? }) catch return error.OutOfMemory;
    }
    const argv = try buildArgv(allocator, options, godot, script_relative, shot_pattern, log_relative, frames_text);

    const game_run = try runGodot(allocator, environ, options.project_root, argv);
    result.exit = exitCode(game_run.term);
    result.signal = switch (game_run.term) {
        .signal => |sig| std.fmt.allocPrint(allocator, "{d}", .{@intFromEnum(sig)}) catch return error.OutOfMemory,
        else => null,
    };
    result.stderr_tail = try tail(allocator, game_run.stderr, 20);

    // Frames: keep the highest-numbered one, drop the rest and the .wav
    // Godot writes beside them, so a sixty-frame run leaves one file.
    if (!options.headless) {
        try collectFrames(allocator, io, options, &result);
    }

    result.errors = try errorLines(allocator, io, result.log_path);
    const log_text = std.Io.Dir.cwd().readFileAlloc(io, result.log_path, allocator, .unlimited) catch "";
    result.log_tail = try tail(allocator, log_text, options.log_lines);
    result.duration_ms = started.durationTo(.now(io, .real)).raw.toMilliseconds();
    return result;
}

/// The Godot command line for the run itself, kept apart from running it so
/// the flags can be asserted without a Godot install.
fn buildArgv(
    allocator: std.mem.Allocator,
    options: Options,
    godot: []const u8,
    script_relative: ?[]const u8,
    shot_pattern: []const u8,
    log_relative: []const u8,
    frames_text: []const u8,
) Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(allocator, &.{ godot, "--path", "." }) catch return error.OutOfMemory;
    if (options.headless) argv.append(allocator, "--headless") catch return error.OutOfMemory;
    if (script_relative) |relative| {
        argv.appendSlice(allocator, &.{ "--script", relative }) catch return error.OutOfMemory;
    } else if (options.scene) |scene| argv.append(allocator, scene) catch return error.OutOfMemory;
    if (!options.headless) {
        argv.appendSlice(allocator, &.{ "--resolution", options.resolution, "--write-movie", shot_pattern }) catch return error.OutOfMemory;
    }
    // Godot advances physics off the wall clock, while --quit-after counts
    // main-loop iterations. Left alone, a 40-frame headless run reaches
    // physics frame 18 on this machine and fewer on a busier one, so a click
    // scheduled at 20 never happens and the run still exits 0. --write-movie
    // forces this same flag (main.cpp), which is why a windowed run was
    // already steady; passing the project's physics rate makes one iteration
    // one physics step, and one frame mean the same thing in both.
    const fixed_fps_text = std.fmt.allocPrint(allocator, "{d}", .{options.physics_fps}) catch return error.OutOfMemory;
    argv.appendSlice(allocator, &.{ "--fixed-fps", fixed_fps_text }) catch return error.OutOfMemory;
    argv.appendSlice(allocator, &.{ "--quit-after", frames_text, "--log-file", log_relative, "--no-header" }) catch return error.OutOfMemory;
    if (options.user_args.len != 0) {
        argv.append(allocator, "--") catch return error.OutOfMemory;
        argv.appendSlice(allocator, options.user_args) catch return error.OutOfMemory;
    }
    return argv.items;
}

/// A SceneTree script that loads the scene and holds the requested actions
/// over their frame ranges. Godot has no flag for injecting input, and this
/// is what the trial agents wrote by hand each time.
fn writeDriverScript(allocator: std.mem.Allocator, io: std.Io, options: Options) Error![]const u8 {
    const scene_arg = options.scene orelse options.main_scene orelse return error.Io;
    const scene_res = if (std.mem.startsWith(u8, scene_arg, "res://")) scene_arg else std.fmt.allocPrint(allocator, "res://{s}", .{std.mem.trimStart(u8, scene_arg, "./")}) catch return error.OutOfMemory;

    var out: std.Io.Writer.Allocating = .init(allocator);
    const w = &out.writer;
    w.writeAll("# Written by godot-cli project run --press; safe to delete.\nextends SceneTree\n\n") catch return error.OutOfMemory;
    w.print("const SCENE := \"{s}\"\nconst PRESSES := [", .{scene_res}) catch return error.OutOfMemory;
    for (options.presses, 0..) |press, i| {
        w.print("{s}[\"{s}\", {d}, {d}]", .{ if (i == 0) "" else ", ", press.action, press.start, press.end }) catch return error.OutOfMemory;
    }
    w.writeAll("]\nconst CLICKS := [") catch return error.OutOfMemory;
    for (options.clicks, 0..) |click, i| {
        w.print("{s}[\"{s}\", {d}]", .{ if (i == 0) "" else ", ", click.node_path, click.frame }) catch return error.OutOfMemory;
    }
    w.writeAll("]\nconst TYPES := [") catch return error.OutOfMemory;
    for (options.types, 0..) |entry, i| {
        w.print("{s}[\"{s}\", {d}, ", .{ if (i == 0) "" else ", ", entry.node_path, entry.frame }) catch return error.OutOfMemory;
        writeGdStringLiteral(w, entry.text) catch return error.OutOfMemory;
        w.writeAll("]") catch return error.OutOfMemory;
    }
    w.writeAll("]\nconst FOCUSES := [") catch return error.OutOfMemory;
    for (options.focuses, 0..) |entry, i| {
        w.print("{s}[\"{s}\", {d}]", .{ if (i == 0) "" else ", ", entry.node_path, entry.frame }) catch return error.OutOfMemory;
    }
    w.print("]\nconst KEEP_CURSOR := {s}\n", .{if (options.keep_cursor) "true" else "false"}) catch return error.OutOfMemory;
    // The headless display server reports no window size, which leaves the
    // root viewport at 64x64 and every Control laid out inside that corner.
    // The driver puts the project's own size back, so a headless run lays out
    // and picks input the way a windowed one does.
    const cross = std.mem.indexOfScalar(u8, options.resolution, 'x') orelse options.resolution.len;
    const width = std.fmt.parseInt(u32, options.resolution[0..cross], 10) catch 640;
    const height = if (cross == options.resolution.len) 360 else std.fmt.parseInt(u32, options.resolution[cross + 1 ..], 10) catch 360;
    w.print("const VIEWPORT := Vector2i({d}, {d})\n", .{ width, height }) catch return error.OutOfMemory;
    // Presses go through parse_input_event as well as the polled action
    // state, so Controls (a focused Button on ui_accept) and scripts polling
    // Input.get_vector both see them. Clicks are a mouse press at the node's
    // centre, released on the next frame, which is what a Button needs.
    //
    // After the release the viewport's cursor is moved off-screen, so the
    // clicked Control gets NOTIFICATION_MOUSE_EXIT and the last frame shows
    // its normal style instead of its hover style. This is a synthetic event
    // through Input.parse_input_event: nothing warps the real pointer.
    w.writeAll(
        \\const AWAY := Vector2(-10000, -10000)
        \\var _frame := 0
        \\
        \\func _initialize() -> void:
        \\    # Not _init(): that runs while the custom main loop is being
        \\    # instantiated, which Godot does before it registers autoload
        \\    # names as script globals (main.cpp sets the main loop, then
        \\    # loads autoloads, then calls initialize). Loading the scene
        \\    # from _init() makes any script naming an autoload fail to
        \\    # compile, so nothing runs at all.
        \\    var packed: PackedScene = load(SCENE)
        \\    if packed == null:
        \\        push_error("godot-cli: cannot load " + SCENE)
        \\        quit(1)
        \\        return
        \\    var instance := packed.instantiate()
        \\    root.add_child(instance)
        \\    # change_scene_to_file removes `current_scene` and nothing else
        \\    # (scene_tree.cpp), so leaving it null means a transition adds the
        \\    # new screen and keeps the old one: both draw at once, and a
        \\    # sign-in that lands on the next screen looks broken.
        \\    current_scene = instance
        \\    # Counting frames from here keeps click and press frames
        \\    # relative to the scene being in the tree.
        \\    physics_frame.connect(_tick)
        \\
        \\func _action(name: String, pressed: bool) -> void:
        \\    if not InputMap.has_action(name):
        \\        push_error("godot-cli: no input action named " + name)
        \\        return
        \\    var event := InputEventAction.new()
        \\    event.action = name
        \\    event.pressed = pressed
        \\    event.strength = 1.0 if pressed else 0.0
        \\    Input.parse_input_event(event)
        \\    if pressed:
        \\        Input.action_press(name)
        \\    else:
        \\        Input.action_release(name)
        \\
        \\func _click(path: String, pressed: bool) -> void:
        \\    var node := root.get_node_or_null(NodePath(path))
        \\    if node == null:
        \\        push_error("godot-cli: no node at " + path + " to click")
        \\        return
        \\    var at := Vector2.ZERO
        \\    if node is Control:
        \\        at = (node as Control).get_global_rect().get_center()
        \\    elif node is Node2D:
        \\        at = (node as Node2D).get_global_transform_with_canvas().origin
        \\    else:
        \\        push_error("godot-cli: " + path + " is not a Control or Node2D")
        \\        return
        \\    # A click outside the viewport reaches nothing, and used to do so
        \\    # in silence: the run passed while the button was never pressed.
        \\    if pressed and not Rect2(Vector2.ZERO, Vector2(root.size)).has_point(at):
        \\        push_error("godot-cli: " + path + " is at " + str(at) + ", outside the " + str(root.size) + " viewport, so the click cannot reach it; the node is laid out beyond the window, or an ancestor has moved it off-screen")
        \\        return
        \\    var event := InputEventMouseButton.new()
        \\    event.button_index = MOUSE_BUTTON_LEFT
        \\    event.pressed = pressed
        \\    event.position = at
        \\    event.global_position = at
        \\    if pressed:
        \\        var motion := InputEventMouseMotion.new()
        \\        motion.position = at
        \\        motion.global_position = at
        \\        Input.parse_input_event(motion)
        \\    Input.parse_input_event(event)
        \\
        \\func _focus(path: String) -> Control:
        \\    var node := root.get_node_or_null(NodePath(path))
        \\    if node == null:
        \\        push_error("godot-cli: no node at " + path)
        \\        return null
        \\    if not (node is Control):
        \\        push_error("godot-cli: " + path + " is not a Control, so it cannot take keyboard focus")
        \\        return null
        \\    var control := node as Control
        \\    control.grab_focus()
        \\    if not control.has_focus():
        \\        push_error("godot-cli: " + path + " did not take focus; its focus_mode may be None")
        \\        return null
        \\    return control
        \\
        \\func _type(path: String, text: String) -> void:
        \\    var control := _focus(path)
        \\    if control == null:
        \\        return
        \\    # Real key events rather than assigning `text`, because a form
        \\    # validates on text_changed and assigning the property emits
        \\    # nothing. The field is emptied first so the result is the text
        \\    # asked for rather than the text appended to whatever was there.
        \\    if control is LineEdit:
        \\        (control as LineEdit).text = ""
        \\    elif control is TextEdit:
        \\        (control as TextEdit).text = ""
        \\    else:
        \\        push_error("godot-cli: " + path + " is a " + control.get_class() + ", not a LineEdit or TextEdit, so there is nowhere for the text to go")
        \\        return
        \\    for i in text.length():
        \\        var down := InputEventKey.new()
        \\        down.unicode = text.unicode_at(i)
        \\        down.pressed = true
        \\        Input.parse_input_event(down)
        \\        var up := InputEventKey.new()
        \\        up.unicode = text.unicode_at(i)
        \\        up.pressed = false
        \\        Input.parse_input_event(up)
        \\
        \\func _mouse_away() -> void:
        \\    var motion := InputEventMouseMotion.new()
        \\    motion.position = AWAY
        \\    motion.global_position = AWAY
        \\    Input.parse_input_event(motion)
        \\
        \\func _tick() -> void:
        \\    _frame += 1
        \\    # Headless reports no window size, so the root viewport sits at
        \\    # 64x64 and a Control laid out for the project's real size ends
        \\    # up outside it. Setting it from _initialize does not survive:
        \\    # the window applies its own size before _ready. Setting it on
        \\    # the first tick sticks, and the layout follows on the next.
        \\    if _frame <= 2 and root.size != VIEWPORT and DisplayServer.get_name() == "headless":
        \\        root.size = VIEWPORT
        \\    for press in PRESSES:
        \\        if _frame == press[1]:
        \\            _action(press[0], true)
        \\        if _frame == press[2] + 1:
        \\            _action(press[0], false)
        \\    for entry in FOCUSES:
        \\        if _frame == entry[1]:
        \\            _focus(entry[0])
        \\    for entry in TYPES:
        \\        if _frame == entry[1]:
        \\            _type(entry[0], entry[2])
        \\    for click in CLICKS:
        \\        if _frame == click[1]:
        \\            _click(click[0], true)
        \\        if _frame == click[1] + 1:
        \\            _click(click[0], false)
        \\            if not KEEP_CURSOR:
        \\                _mouse_away()
        \\
    ) catch return error.OutOfMemory;

    const relative = std.fmt.allocPrint(allocator, "{s}/godot_cli_run.gd", .{options.capture_dir}) catch return error.OutOfMemory;
    const full = std.fs.path.join(allocator, &.{ options.project_root, relative }) catch return error.OutOfMemory;
    const file = std.Io.Dir.cwd().createFile(io, full, .{}) catch return error.Io;
    defer file.close(io);
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    writer.interface.writeAll(out.written()) catch return error.Io;
    writer.interface.flush() catch return error.Io;
    return relative;
}

/// A GDScript string literal. The text is a password or an address as often
/// as not, so a quote or a backslash in it must not end the literal early.
fn writeGdStringLiteral(w: *std.Io.Writer, text: []const u8) !void {
    try w.writeAll("\"");
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

fn clearCapture(allocator: std.mem.Allocator, io: std.Io, options: Options) Error!void {
    const dir_path = std.fs.path.join(allocator, &.{ options.project_root, options.capture_dir }) catch return error.OutOfMemory;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.Io;
    defer dir.close(io);
    var stale: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return error.Io) |entry| {
        if (entry.kind != .file) continue;
        const is_frame = std.mem.startsWith(u8, entry.name, "shot") and std.mem.endsWith(u8, entry.name, ".png");
        if (is_frame or std.mem.endsWith(u8, entry.name, ".wav")) {
            stale.append(allocator, allocator.dupe(u8, entry.name) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
    }
    for (stale.items) |name| dir.deleteFile(io, name) catch {};
}

fn collectFrames(allocator: std.mem.Allocator, io: std.Io, options: Options, result: *Result) Error!void {
    const dir_path = std.fs.path.join(allocator, &.{ options.project_root, options.capture_dir }) catch return error.OutOfMemory;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.Io;
    defer dir.close(io);

    var frames: std.ArrayList([]const u8) = .empty;
    var wavs: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(io) catch return error.Io) |entry| {
        if (entry.kind != .file) continue;
        const name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
        if (std.mem.startsWith(u8, name, "shot") and std.mem.endsWith(u8, name, ".png")) {
            frames.append(allocator, name) catch return error.OutOfMemory;
        } else if (std.mem.endsWith(u8, name, ".wav")) {
            wavs.append(allocator, name) catch return error.OutOfMemory;
        }
    }
    result.frames_written = frames.items.len;
    if (frames.items.len == 0) return;

    // Godot zero-pads frame numbers, so the lexicographic maximum is the last.
    var last = frames.items[0];
    for (frames.items[1..]) |name| if (std.mem.order(u8, name, last) == .gt) {
        last = name;
    };
    result.frame = std.fs.path.join(allocator, &.{ dir_path, last }) catch return error.OutOfMemory;

    var keep_names: std.ArrayList([]const u8) = .empty;
    var kept_paths: std.ArrayList([]const u8) = .empty;
    for (options.frames_at) |wanted| {
        const name = std.fmt.allocPrint(allocator, "shot{d:0>8}.png", .{wanted}) catch return error.OutOfMemory;
        keep_names.append(allocator, name) catch return error.OutOfMemory;
        for (frames.items) |written| if (std.mem.eql(u8, written, name)) {
            kept_paths.append(allocator, std.fs.path.join(allocator, &.{ dir_path, written }) catch return error.OutOfMemory) catch return error.OutOfMemory;
        };
    }
    result.frame_at_paths = kept_paths.items;

    if (!options.keep_frames) {
        for (frames.items) |name| {
            if (std.mem.eql(u8, name, last)) continue;
            var wanted = false;
            for (keep_names.items) |keep| {
                if (std.mem.eql(u8, name, keep)) wanted = true;
            }
            if (wanted) continue;
            dir.deleteFile(io, name) catch {};
        }
        for (wavs.items) |name| dir.deleteFile(io, name) catch {};
    }
}

/// Lines from the log that report an error, each with the indented
/// backtrace lines Godot prints after it. Capped so a runaway loop cannot
/// turn the result into the whole log.
fn errorLines(allocator: std.mem.Allocator, io: std.Io, log_path: []const u8) Error![]const []const u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(io, log_path, allocator, .unlimited) catch return &.{};
    var out: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var in_error = false;
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const is_error = std.mem.startsWith(u8, line, "ERROR") or std.mem.startsWith(u8, line, "SCRIPT ERROR") or std.mem.startsWith(u8, line, "USER ERROR") or std.mem.indexOf(u8, line, "SCRIPT ERROR:") != null;
        const is_continuation = in_error and line.len > 0 and (line[0] == ' ' or line[0] == '\t');
        if (is_error or is_continuation) {
            if (out.items.len >= 60) break;
            out.append(allocator, line) catch return error.OutOfMemory;
            in_error = true;
        } else {
            in_error = false;
        }
    }
    return out.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

fn tail(allocator: std.mem.Allocator, text: []const u8, max_lines: usize) Error![]const u8 {
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    if (trimmed.len == 0) return "";
    var count: usize = 0;
    var index = trimmed.len;
    while (index > 0) : (index -= 1) {
        if (trimmed[index - 1] == '\n') {
            count += 1;
            if (count == max_lines) return allocator.dupe(u8, trimmed[index..]) catch return error.OutOfMemory;
        }
    }
    return allocator.dupe(u8, trimmed) catch return error.OutOfMemory;
}

test "error lines carry their backtrace and stop at the next plain line" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.writeFile(io, .{ .sub_path = "godot.log", .data = "hello\nSCRIPT ERROR: Invalid access to property 'x'.\n   at: _ready (res://main.gd:4)\nfine again\nERROR: deliberate\n" });
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const dir_path = path_buf[0..dir_len];
    const log_path = try std.fs.path.join(arena, &.{ dir_path, "godot.log" });

    const lines = try errorLines(arena, io, log_path);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expect(std.mem.startsWith(u8, lines[0], "SCRIPT ERROR"));
    try std.testing.expect(std.mem.startsWith(u8, lines[1], "   at:"));
    try std.testing.expectEqualStrings("ERROR: deliberate", lines[2]);
}

test "press syntax" {
    const range = parsePress("move_right@10..40").?;
    try std.testing.expectEqualStrings("move_right", range.action);
    try std.testing.expectEqual(@as(u32, 10), range.start);
    try std.testing.expectEqual(@as(u32, 40), range.end);
    const single = parsePress("ui_accept@5").?;
    try std.testing.expectEqual(single.start, single.end);
    try std.testing.expect(parsePress("nope") == null);
    try std.testing.expect(parsePress("x@0") == null);
    try std.testing.expect(parsePress("x@9..3") == null);
}

test "click syntax" {
    const click = parseClick("/root/Main/HUD/PauseButton@20").?;
    try std.testing.expectEqualStrings("/root/Main/HUD/PauseButton", click.node_path);
    try std.testing.expectEqual(@as(u32, 20), click.frame);
    try std.testing.expect(parseClick("@3") == null);
    try std.testing.expect(parseClick("/root/X") == null);
}

test "tail keeps the last lines" {
    const allocator = std.testing.allocator;
    const text = try tail(allocator, "a\nb\nc\nd\n", 2);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("c\nd", text);
}

test "the driver script moves the cursor off the node after a click, unless it is kept" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "cap");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..dir_len];

    var options = Options{
        .project_root = root,
        .scene = "main.tscn",
        .capture_dir = "cap",
        .clicks = &.{.{ .node_path = "/root/Main/Play", .frame = 20 }},
    };
    const relative = try writeDriverScript(arena, io, options);
    const script_path = try std.fs.path.join(arena, &.{ root, relative });
    const moved = try std.Io.Dir.cwd().readFileAlloc(io, script_path, arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, moved, "res://main.tscn") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "const KEEP_CURSOR := false") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "const AWAY := Vector2(-10000, -10000)") != null);
    // The move happens after the release, not with the press, or the click
    // would land on nothing.
    const away_call = std.mem.indexOf(u8, moved, "            if not KEEP_CURSOR:\n                _mouse_away()").?;
    const release = std.mem.indexOf(u8, moved, "_click(click[0], false)").?;
    try std.testing.expect(away_call > release);

    // change_scene_to_file removes `current_scene` and nothing else, so a
    // driver that never sets it leaves the old screen in the tree: a sign-in
    // that lands on the next screen draws both at once. A trial read that as
    // a capture artifact and called the transition verified.
    const add_child = std.mem.indexOf(u8, moved, "root.add_child(instance)").?;
    const set_current = std.mem.indexOf(u8, moved, "current_scene = instance").?;
    try std.testing.expect(add_child < set_current);

    // The scene is loaded from _initialize, never from _init: _init runs
    // before Godot registers autoloads, so a scene whose script names one
    // fails to compile and nothing runs at all.
    try std.testing.expect(std.mem.indexOf(u8, moved, "func _initialize() -> void:") != null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "func _init() -> void:") == null);
    try std.testing.expect(std.mem.indexOf(u8, moved, "load(SCENE)").? > std.mem.indexOf(u8, moved, "func _initialize").?);

    options.keep_cursor = true;
    _ = try writeDriverScript(arena, io, options);
    const kept = try std.Io.Dir.cwd().readFileAlloc(io, script_path, arena, .unlimited);
    try std.testing.expect(std.mem.indexOf(u8, kept, "const KEEP_CURSOR := true") != null);
}

test "the command line pins the frame rate, so a frame number means the same thing in both modes" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // A click at frame 20 of a 40-frame run only happens if 40 iterations
    // are 40 frames. Godot ties physics to the wall clock unless told not
    // to, and only --write-movie (windowed) forces that for us.
    const headless = try buildArgv(arena, .{
        .project_root = ".",
        .headless = true,
        .physics_fps = 60,
    }, "godot", "cap/driver.gd", "cap/shot.png", "cap/godot.log", "40");
    const fixed = indexOfArg(headless, "--fixed-fps").?;
    try std.testing.expectEqualStrings("60", headless[fixed + 1]);
    try std.testing.expect(indexOfArg(headless, "--write-movie") == null);

    // A project that ticks at 30 counts frames at 30, rather than being run
    // at a fixed 60 that drifts two iterations to its every physics step.
    const slow = try buildArgv(arena, .{
        .project_root = ".",
        .physics_fps = 30,
        .resolution = "1920x1080",
    }, "godot", null, "cap/shot.png", "cap/godot.log", "40");
    try std.testing.expectEqualStrings("30", slow[indexOfArg(slow, "--fixed-fps").? + 1]);
    try std.testing.expect(indexOfArg(slow, "--write-movie") != null);
}

fn indexOfArg(argv: []const []const u8, flag: []const u8) ?usize {
    for (argv, 0..) |arg, i| if (std.mem.eql(u8, arg, flag)) return i;
    return null;
}

test "the driver script puts the project's viewport size back under headless" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "cap");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..dir_len];

    const relative = try writeDriverScript(arena, io, .{
        .project_root = root,
        .scene = "main.tscn",
        .capture_dir = "cap",
        .resolution = "1920x1080",
        .clicks = &.{.{ .node_path = "/root/Main/Play", .frame = 20 }},
    });
    const script = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ root, relative }), arena, .unlimited);

    // The headless display server reports no window size, which leaves the
    // root viewport at 64x64: every Control lands in that corner and a click
    // aimed at the layout the project describes reaches nothing.
    try std.testing.expect(std.mem.indexOf(u8, script, "const VIEWPORT := Vector2i(1920, 1080)") != null);
    const restore = std.mem.indexOf(u8, script, "root.size = VIEWPORT").?;
    // Only headless: a windowed run already has the size and setting it
    // would fight the window.
    try std.testing.expect(std.mem.indexOf(u8, script[0..restore], "DisplayServer.get_name() == \"headless\"") != null);
    // Before the first click, or the click is computed against 64x64.
    try std.testing.expect(restore < std.mem.indexOf(u8, script, "_click(click[0], true)").?);
    // From _tick, not _initialize: the window applies its own size before
    // _ready, so a size set during _initialize does not survive.
    try std.testing.expect(restore > std.mem.indexOf(u8, script, "func _tick() -> void:").?);
}

test "typing syntax survives an address and a password" {
    // The frame sits between the last @ of the target and the first = of the
    // text, so neither an email nor an = in a password breaks the parse.
    const email = parseTypeText("/root/Main/%Email@10=someone@example.com").?;
    try std.testing.expectEqualStrings("/root/Main/%Email", email.node_path);
    try std.testing.expectEqual(@as(u32, 10), email.frame);
    try std.testing.expectEqualStrings("someone@example.com", email.text);

    const password = parseTypeText("/root/Main/%Password@14=p=ss@w0rd").?;
    try std.testing.expectEqualStrings("/root/Main/%Password", password.node_path);
    try std.testing.expectEqualStrings("p=ss@w0rd", password.text);

    // Emptying a field is a thing worth being able to ask for.
    try std.testing.expectEqualStrings("", parseTypeText("/root/Main/%Email@3=").?.text);

    try std.testing.expect(parseTypeText("/root/Main/%Email@10") == null);
    try std.testing.expect(parseTypeText("/root/Main/%Email=text") == null);
    try std.testing.expect(parseTypeText("/root/Main/%Email@0=text") == null);
    try std.testing.expect(parseTypeText("@10=text") == null);

    const focus = parseFocus("/root/Main/%Email@7").?;
    try std.testing.expectEqualStrings("/root/Main/%Email", focus.node_path);
    try std.testing.expectEqual(@as(u32, 7), focus.frame);
}

test "the driver types with real keys, into an emptied field, after focusing it" {
    const allocator = std.testing.allocator;
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, "cap");
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_len = try tmp.dir.realPath(io, &path_buf);
    const root = path_buf[0..dir_len];

    const relative = try writeDriverScript(arena, io, .{
        .project_root = root,
        .scene = "signin.tscn",
        .capture_dir = "cap",
        .types = &.{.{ .node_path = "/root/Main/%Email", .frame = 10, .text = "a\"b\\c" }},
    });
    const script = try std.Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ root, relative }), arena, .unlimited);

    // A quote or a backslash in a password must not end the GDScript literal.
    try std.testing.expect(std.mem.indexOf(u8, script, "[\"/root/Main/%Email\", 10, \"a\\\"b\\\\c\"]") != null);

    // Assigning `text` emits nothing, and a validating form runs on
    // text_changed, so the text goes in as key events.
    try std.testing.expect(std.mem.indexOf(u8, script, "InputEventKey.new()") != null);

    // Asserted inside _type's own body, so an anchor that merely happens to
    // sit earlier in the file cannot satisfy it.
    const body_start = std.mem.indexOf(u8, script, "func _type(path: String, text: String) -> void:").?;
    const body = script[body_start..std.mem.indexOfPos(u8, script, body_start + 1, "\nfunc ").?];

    const focus_call = std.mem.indexOf(u8, body, "_focus(path)").?;
    const guard = std.mem.indexOf(u8, body, "if control == null:").?;
    const clear = std.mem.indexOf(u8, body, "(control as LineEdit).text = \"\"").?;
    const keys = std.mem.indexOf(u8, body, "down.unicode = text.unicode_at(i)").?;

    // Focus first and bail if it did not take, or the keys land on whatever
    // was focused before -- silently typing into the wrong field.
    try std.testing.expect(focus_call < guard);
    try std.testing.expect(guard < clear);
    // Empty before typing, so the result is the text asked for rather than
    // the text appended to a default.
    try std.testing.expect(clear < keys);
}
