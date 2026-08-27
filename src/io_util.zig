//! Synchronous file I/O using Zig's single-threaded Io instance.
//! Avoids EINVAL on stdout after file ops when the main CLI uses threaded Io.

const std = @import("std");

fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(syncIo(), path, allocator, .unlimited);
}

/// Write `data` to `path`, replacing any existing file atomically.
///
/// This tool edits files in a user's Godot project, so a partial write is worse
/// than a failed one: truncating a `.tscn` loses work the editor cannot recover.
/// Writing to a sibling temporary and renaming means an interrupted run leaves
/// the original untouched.
pub fn writeFileAtomic(io: std.Io, path: []const u8, data: []const u8) !void {
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);

    try atomic.file.writeStreamingAll(io, data);
    try atomic.replace(io);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    return writeFileAtomic(syncIo(), path, data);
}

/// Write `data` to `path`, creating the parent directory first when it is
/// missing.
///
/// The id session cache lives in `<project>/.godot/`, which Godot creates when
/// it first imports a project. A project checked out fresh — on CI, or by
/// anyone who has not opened it in the editor yet — has no such directory, and
/// a plain write there fails with FileNotFound.
pub fn writeFileCreatingParent(path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |parent| {
        if (parent.len != 0) {
            std.Io.Dir.cwd().createDirPath(syncIo(), parent) catch {};
        }
    }
    return writeFileAtomic(syncIo(), path, data);
}
