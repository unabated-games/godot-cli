//! Read and write Godot `.godot/uid_cache.bin` files.
//! Ported from `core/io/resource_uid.cpp`.

const std = @import("std");
const resource_uid = @import("resource_uid.zig");

pub const Entry = struct {
    id: i64,
    path: []const u8,
};

pub const Cache = struct {
    entries: std.ArrayList(Entry),

    pub fn init(allocator: std.mem.Allocator) Cache {
        _ = allocator;
        return .{
            .entries = .empty,
        };
    }

    pub fn deinit(self: *Cache, allocator: std.mem.Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.path);
        }
        self.entries.deinit(allocator);
    }

    pub fn pathForId(self: *const Cache, id: i64) ?[]const u8 {
        for (self.entries.items) |entry| {
            if (entry.id == id) return entry.path;
        }
        return null;
    }

    pub fn idForPath(self: *const Cache, path: []const u8) ?i64 {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.path, path)) return entry.id;
        }
        return null;
    }

    pub fn hasId(self: *const Cache, id: i64) bool {
        return self.pathForId(id) != null;
    }
};

pub const LoadError = error{
    Io,
    Corrupt,
    OutOfMemory,
};

pub fn defaultCachePath(allocator: std.mem.Allocator, project_root: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ project_root, ".godot", "uid_cache.bin" });
}

pub fn loadFromFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) LoadError!Cache {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);
    return loadFromBytes(allocator, bytes);
}

pub fn loadFromBytes(allocator: std.mem.Allocator, bytes: []const u8) LoadError!Cache {
    var cache = Cache.init(allocator);
    errdefer cache.deinit(allocator);

    var offset: usize = 0;
    const entry_count = try readU32(bytes, &offset);
    var i: u32 = 0;
    while (i < entry_count) : (i += 1) {
        const id: i64 = @bitCast(try readU64(bytes, &offset));
        const path_len = try readU32(bytes, &offset);
        if (offset + path_len > bytes.len) return error.Corrupt;
        const path = try allocator.dupe(u8, bytes[offset .. offset + path_len]);
        offset += path_len;
        try cache.entries.append(allocator, .{ .id = id, .path = path });
    }

    if (offset != bytes.len) return error.Corrupt;
    return cache;
}

pub fn encode(allocator: std.mem.Allocator, entries: []const Entry) ![]u8 {
    var size: usize = 4;
    for (entries) |entry| {
        size += 8 + 4 + entry.path.len;
    }

    var out = try allocator.alloc(u8, size);
    var offset: usize = 0;
    writeU32(out, &offset, @intCast(entries.len));
    for (entries) |entry| {
        writeU64(out, &offset, @bitCast(entry.id));
        writeU32(out, &offset, @intCast(entry.path.len));
        @memcpy(out[offset .. offset + entry.path.len], entry.path);
        offset += entry.path.len;
    }
    return out;
}

pub fn saveToFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8, entries: []const Entry) !void {
    const data = try encode(allocator, entries);
    defer allocator.free(data);
    try std.Io.Dir.cwd().writeFile(io, path, data);
}

fn readU32(bytes: []const u8, offset: *usize) LoadError!u32 {
    if (offset.* + 4 > bytes.len) return error.Corrupt;
    var buf: [4]u8 = undefined;
    @memcpy(&buf, bytes[offset.* .. offset.* + 4]);
    offset.* += 4;
    return std.mem.readInt(u32, &buf, .little);
}

fn readU64(bytes: []const u8, offset: *usize) LoadError!u64 {
    if (offset.* + 8 > bytes.len) return error.Corrupt;
    var buf: [8]u8 = undefined;
    @memcpy(&buf, bytes[offset.* .. offset.* + 8]);
    offset.* += 8;
    return std.mem.readInt(u64, &buf, .little);
}

fn writeU32(out: []u8, offset: *usize, value: u32) void {
    var buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &buf, value, .little);
    @memcpy(out[offset.* .. offset.* + 4], &buf);
    offset.* += 4;
}

fn writeU64(out: []u8, offset: *usize, value: u64) void {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &buf, value, .little);
    @memcpy(out[offset.* .. offset.* + 8], &buf);
    offset.* += 8;
}

test "round trip encode and load" {
    const allocator = std.testing.allocator;
    const entries = [_]Entry{
        .{ .id = 1350303725746704497, .path = "res://test.tscn" },
        .{ .id = 42, .path = "res://icon.svg" },
    };

    const encoded = try encode(allocator, &entries);
    defer allocator.free(encoded);

    var cache = try loadFromBytes(allocator, encoded);
    defer cache.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), cache.entries.items.len);
    try std.testing.expectEqual(@as(i64, 42), cache.idForPath("res://icon.svg"));
    try std.testing.expectEqualStrings("res://test.tscn", cache.pathForId(1350303725746704497).?);
}
