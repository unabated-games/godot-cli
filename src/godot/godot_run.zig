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
    /// Relative to the project root. Created with a `.gdignore` if missing.
    capture_dir: []const u8 = "capture",
    import: bool = true,
    /// Keep every frame; the default keeps only the last and drops the .wav.
    keep_frames: bool = false,
    /// No window and no frames, only the log. For machines without a display.
    headless: bool = false,
    /// Passed after `--`; reachable from OS.get_cmdline_user_args().
    user_args: []const []const u8 = &.{},
};

pub const Result = struct {
    godot: []const u8,
    import_exit: ?u8 = null,
    exit: ?u8 = null,
    signal: ?[]const u8 = null,
    frame: ?[]const u8 = null,
    frames_written: usize = 0,
    log_path: []const u8,
    errors: []const []const u8,
    stderr_tail: []const u8,
    duration_ms: i64,
};

pub const Error = error{
    GodotNotFound,
    OutOfMemory,
    Io,
    SpawnFailed,
};

const macos_default = "/Applications/Godot.app/Contents/MacOS/Godot";

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

    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(allocator, &.{ godot, "--path", "." }) catch return error.OutOfMemory;
    if (options.headless) argv.append(allocator, "--headless") catch return error.OutOfMemory;
    if (options.scene) |scene| argv.append(allocator, scene) catch return error.OutOfMemory;
    if (!options.headless) {
        argv.appendSlice(allocator, &.{ "--resolution", options.resolution, "--write-movie", shot_pattern }) catch return error.OutOfMemory;
    }
    argv.appendSlice(allocator, &.{ "--quit-after", frames_text, "--log-file", log_relative, "--no-header" }) catch return error.OutOfMemory;
    if (options.user_args.len != 0) {
        argv.append(allocator, "--") catch return error.OutOfMemory;
        argv.appendSlice(allocator, options.user_args) catch return error.OutOfMemory;
    }

    const game_run = try runGodot(allocator, environ, options.project_root, argv.items);
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
    result.duration_ms = started.durationTo(.now(io, .real)).raw.toMilliseconds();
    return result;
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

    if (!options.keep_frames) {
        for (frames.items) |name| if (!std.mem.eql(u8, name, last)) {
            dir.deleteFile(io, name) catch {};
        };
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

test "tail keeps the last lines" {
    const allocator = std.testing.allocator;
    const text = try tail(allocator, "a\nb\nc\nd\n", 2);
    defer allocator.free(text);
    try std.testing.expectEqualStrings("c\nd", text);
}
