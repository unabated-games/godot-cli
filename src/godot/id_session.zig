//! Persistent ext_resource id cache keyed by referrer scene path.
//! Mirrors Godot editor `Resource::set_id_for_path` / `get_id_for_path` (TOOLS_ENABLED).

const std = @import("std");
const io_util = @import("../io_util.zig");
const document = @import("text_format/document.zig");

pub const Session = struct {
    referrers: std.StringHashMap(ExtMap),

    const ExtMap = std.StringHashMap([]const u8);

    pub fn init(allocator: std.mem.Allocator) Session {
        return .{ .referrers = std.StringHashMap(ExtMap).init(allocator) };
    }

    pub fn deinit(self: *Session, allocator: std.mem.Allocator) void {
        var ref_it = self.referrers.iterator();
        while (ref_it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            var ext_it = entry.value_ptr.iterator();
            while (ext_it.next()) |ext| {
                allocator.free(ext.key_ptr.*);
                allocator.free(ext.value_ptr.*);
            }
            entry.value_ptr.deinit();
        }
        self.referrers.deinit();
    }

    /// Import ext_resource path → id mappings from a parsed scene (e.g. Godot-saved reference).
    pub fn importExtResourceIdsFromDocument(
        self: *Session,
        allocator: std.mem.Allocator,
        referrer_path: []const u8,
        doc: *const document.Document,
    ) !usize {
        var count: usize = 0;
        for (doc.sections.items) |section| {
            if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
            const ext_path = section.header.getString("path") orelse continue;
            const id = section.header.getString("id") orelse continue;
            try self.setExtId(allocator, referrer_path, ext_path, id);
            count += 1;
        }
        return count;
    }

    pub fn getExtId(self: *const Session, referrer_path: []const u8, ext_path: []const u8) ?[]const u8 {
        const map = self.referrers.get(referrer_path) orelse return null;
        return map.get(ext_path);
    }

    pub fn setExtId(self: *Session, allocator: std.mem.Allocator, referrer_path: []const u8, ext_path: []const u8, id: []const u8) !void {
        const gop = try self.referrers.getOrPut(referrer_path);
        if (!gop.found_existing) {
            gop.value_ptr.* = ExtMap.init(allocator);
            const owned_referrer = try allocator.dupe(u8, referrer_path);
            gop.key_ptr.* = owned_referrer;
        }

        const map = gop.value_ptr;
        const ext_gop = try map.getOrPut(ext_path);
        const owned_ext = try allocator.dupe(u8, ext_path);
        const owned_id = try allocator.dupe(u8, id);
        if (ext_gop.found_existing) {
            allocator.free(owned_ext);
            allocator.free(ext_gop.value_ptr.*);
            ext_gop.value_ptr.* = owned_id;
        } else {
            ext_gop.key_ptr.* = owned_ext;
            ext_gop.value_ptr.* = owned_id;
        }
    }

    pub fn loadFromFile(allocator: std.mem.Allocator, path: []const u8) !Session {
        const bytes = try io_util.readFileAlloc(allocator, path);
        defer allocator.free(bytes);

        var session = init(allocator);
        errdefer session.deinit(allocator);

        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, bytes, .{});
        defer parsed.deinit();

        const root = parsed.value;
        if (root != .object) return session;

        const referrers = root.object.get("referrers") orelse return session;
        if (referrers != .object) return session;

        var ref_it = referrers.object.iterator();
        while (ref_it.next()) |ref_entry| {
            if (ref_entry.value_ptr.* != .object) continue;
            var ext_it = ref_entry.value_ptr.object.iterator();
            while (ext_it.next()) |ext_entry| {
                if (ext_entry.value_ptr.* != .string) continue;
                try session.setExtId(allocator, ref_entry.key_ptr.*, ext_entry.key_ptr.*, ext_entry.value_ptr.string);
            }
        }

        return session;
    }

    pub fn saveToFile(self: *const Session, path: []const u8) !void {
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(self.referrers.allocator);

        try out.appendSlice(self.referrers.allocator, "{\n  \"version\": 1,\n  \"referrers\": {\n");

        var ref_it = self.referrers.iterator();
        var first_ref = true;
        while (ref_it.next()) |ref_entry| {
            if (!first_ref) try out.appendSlice(self.referrers.allocator, ",\n");
            first_ref = false;

            try out.appendSlice(self.referrers.allocator, "    ");
            try appendJsonString(self.referrers.allocator, &out, ref_entry.key_ptr.*);
            try out.appendSlice(self.referrers.allocator, ": {\n");

            var ext_it = ref_entry.value_ptr.iterator();
            var first_ext = true;
            while (ext_it.next()) |ext_entry| {
                if (!first_ext) try out.appendSlice(self.referrers.allocator, ",\n");
                first_ext = false;
                try out.appendSlice(self.referrers.allocator, "      ");
                try appendJsonString(self.referrers.allocator, &out, ext_entry.key_ptr.*);
                try out.appendSlice(self.referrers.allocator, ": ");
                try appendJsonString(self.referrers.allocator, &out, ext_entry.value_ptr.*);
            }
            try out.appendSlice(self.referrers.allocator, "\n    }");
        }

        try out.appendSlice(self.referrers.allocator, "\n  }\n}\n");
        try io_util.writeFileCreatingParent(path, out.items);
    }

    pub fn defaultPath(allocator: std.mem.Allocator, project_root: []const u8) ![]const u8 {
        return std.fs.path.join(allocator, &.{ project_root, ".godot", "scene_id_cache.json" });
    }
};

fn appendJsonString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    try out.append(allocator, '"');
    for (text) |c| {
        switch (c) {
            '"', '\\' => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
            else => try out.append(allocator, c),
        }
    }
    try out.append(allocator, '"');
}

test "round trip session json" {
    const allocator = std.testing.allocator;
    var session = Session.init(allocator);
    defer session.deinit(allocator);

    try session.setExtId(allocator, "res://sample.tscn", "res://id_reference.gd", "1_a7oy8");

    const path = "test_id_session.json";
    defer std.Io.Dir.cwd().deleteFile(std.Io.Threaded.global_single_threaded.io(), path) catch {};
    try session.saveToFile(path);

    var loaded = try Session.loadFromFile(allocator, path);
    defer loaded.deinit(allocator);

    try std.testing.expectEqualStrings("1_a7oy8", loaded.getExtId("res://sample.tscn", "res://id_reference.gd").?);
}
