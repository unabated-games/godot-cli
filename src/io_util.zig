//! Synchronous file I/O using Zig's single-threaded Io instance.
//! Avoids EINVAL on stdout after file ops when the main CLI uses threaded Io.

const std = @import("std");

fn syncIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(syncIo(), path, allocator, .unlimited);
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    try std.Io.Dir.cwd().writeFile(syncIo(), .{ .sub_path = path, .data = data });
}
