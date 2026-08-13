//! Godot-compatible save preparation: scene-local ID assignment and ext_resource ordering.
//! Ported from `scene/resources/resource_format_text.cpp` (editor save path).

const std = @import("std");
const scene_id = @import("../scene_id.zig");
const node_id = @import("../node_id.zig");
const id_validate = @import("../id_validate.zig");
const id_session = @import("../id_session.zig");
const document = @import("document.zig");
const godot_format = @import("godot_format.zig");
const node_section_order = @import("../node_section_order.zig");
const tag = @import("tag.zig");

pub const SaveOptions = struct {
    /// Path used to seed `Resource::seed_scene_unique_id` (typically `res://…` or save target).
    seed_path: []const u8,
    repair_ids: bool = true,
    sort_ext_resources: bool = true,
    update_load_steps: bool = true,
    assign_node_unique_ids: bool = true,
    sort_node_sections: bool = true,
    id_session: ?*id_session.Session = null,
    godot_save_format: bool = false,
};

pub const PrepareError = error{
    OutOfMemory,
} || node_section_order.Error || scene_id.Error || node_id.Error;

pub fn prepareDocument(allocator: std.mem.Allocator, doc: *document.Document, options: SaveOptions) PrepareError!void {
    scene_id.resetSceneUniqueIdGenerator();
    scene_id.seedSceneUniqueIdFromPath(options.seed_path);

    if (options.repair_ids) {
        try assignSceneIds(allocator, doc, options);
    }
    if (options.sort_ext_resources) {
        try sortResourceSections(allocator, doc);
        try sortExtResourceSections(allocator, doc);
    }
    if (options.update_load_steps) {
        updateLoadSteps(doc);
    }
    if (options.assign_node_unique_ids) {
        try assignNodeUniqueIds(allocator, doc, options.seed_path);
    }
    if (options.sort_node_sections) {
        try node_section_order.sortNodeSections(allocator, doc);
    }
    if (options.id_session) |session| {
        try recordExtResourceIds(allocator, doc, options.seed_path, session);
    }
    if (options.godot_save_format) {
        try godot_format.applyGodotSaveFormat(allocator, doc);
    }
}

fn assignSceneIds(allocator: std.mem.Allocator, doc: *document.Document, options: SaveOptions) !void {
    var used_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = used_ids.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        used_ids.deinit();
    }

    var remap = std.StringHashMap([]const u8).init(allocator);
    defer {
        var it = remap.iterator();
        while (it.next()) |entry| {
            allocator.free(entry.key_ptr.*);
            allocator.free(entry.value_ptr.*);
        }
        remap.deinit();
    }

    var ext_index: u32 = 1;
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;

        const ext_path = section.header.getString("path");
        const existing = section.header.getString("id");

        var cached_id: ?[]const u8 = null;
        if (options.id_session) |session| {
            if (ext_path) |path| {
                if (session.getExtId(options.seed_path, path)) |cached| {
                    if (!used_ids.contains(cached)) cached_id = cached;
                }
            }
        }

        const new_id = if (cached_id) |cached|
            try allocator.dupe(u8, cached)
        else
            try resolveExtResourceId(allocator, existing, ext_index, &used_ids);
        defer allocator.free(new_id);
        ext_index += 1;

        if (existing) |old_id| {
            if (!std.mem.eql(u8, old_id, new_id)) {
                try putRemap(allocator, &remap, old_id, new_id);
            }
        }

        try section.header.setStringField(allocator, "id", new_id);
        const owned = try allocator.dupe(u8, new_id);
        const gop = try used_ids.getOrPut(owned);
        if (gop.found_existing) allocator.free(owned);
    }

    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;

        const type_name = section.header.getString("type") orelse "Resource";
        const existing = section.header.getString("id");
        const new_id = try resolveSubResourceId(allocator, type_name, existing, &used_ids);
        defer allocator.free(new_id);

        if (existing) |old_id| {
            if (!std.mem.eql(u8, old_id, new_id)) {
                try putRemap(allocator, &remap, old_id, new_id);
            }
        }

        try section.header.setStringField(allocator, "id", new_id);
        const owned = try allocator.dupe(u8, new_id);
        const gop = try used_ids.getOrPut(owned);
        if (gop.found_existing) allocator.free(owned);
    }

    if (remap.count() > 0) {
        try applyIdRemap(allocator, doc, &remap);
    }
}

fn putRemap(allocator: std.mem.Allocator, remap: *std.StringHashMap([]const u8), old_id: []const u8, new_id: []const u8) !void {
    const owned_old = try allocator.dupe(u8, old_id);
    errdefer allocator.free(owned_old);
    const owned_new = try allocator.dupe(u8, new_id);
    errdefer allocator.free(owned_new);
    const gop = try remap.getOrPut(owned_old);
    if (gop.found_existing) {
        allocator.free(owned_old);
        allocator.free(owned_new);
    } else {
        gop.value_ptr.* = owned_new;
    }
}

fn resolveExtResourceId(
    allocator: std.mem.Allocator,
    existing: ?[]const u8,
    index: u32,
    used: *std.StringHashMap(void),
) ![]u8 {
    if (existing) |id| {
        if (!used.contains(id)) return try allocator.dupe(u8, id);
        const prefix = idPrefix(id) orelse try std.fmt.allocPrint(allocator, "{d}_", .{index});
        defer if (idPrefix(id) == null) allocator.free(prefix);
        return generateUniqueId(allocator, prefix, used);
    }
    const prefix = try std.fmt.allocPrint(allocator, "{d}_", .{index});
    defer allocator.free(prefix);
    return generateUniqueId(allocator, prefix, used);
}

fn resolveSubResourceId(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    existing: ?[]const u8,
    used: *std.StringHashMap(void),
) ![]u8 {
    if (existing) |id| {
        if (!used.contains(id)) return try allocator.dupe(u8, id);
        const prefix = idPrefix(id) orelse try std.fmt.allocPrint(allocator, "{s}_", .{type_name});
        defer if (idPrefix(id) == null) allocator.free(prefix);
        return generateUniqueId(allocator, prefix, used);
    }
    const prefix = try std.fmt.allocPrint(allocator, "{s}_", .{type_name});
    defer allocator.free(prefix);
    return generateUniqueId(allocator, prefix, used);
}

fn idPrefix(id: []const u8) ?[]const u8 {
    const at = std.mem.lastIndexOfScalar(u8, id, '_') orelse return null;
    return id[0 .. at + 1];
}

fn generateUniqueId(allocator: std.mem.Allocator, prefix: []const u8, used: *std.StringHashMap(void)) ![]u8 {
    while (true) {
        const suffix = try scene_id.generateSceneUniqueId();
        const id = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prefix, &suffix });
        if (!used.contains(id)) return id;
        allocator.free(id);
    }
}

fn applyIdRemap(allocator: std.mem.Allocator, doc: *document.Document, remap: *const std.StringHashMap([]const u8)) !void {
    const patterns = [_][]const u8{ "ExtResource(\"", "SubResource(\"" };

    for (doc.sections.items) |*section| {
        for (section.properties.items, 0..) |prop, prop_index| {
            var changed = false;
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);

            var cursor: usize = 0;
            while (cursor < prop.raw.len) {
                var best: ?struct { start: usize, prefix: []const u8 } = null;
                for (patterns) |prefix| {
                    if (std.mem.indexOfPos(u8, prop.raw, cursor, prefix)) |found| {
                        if (best == null or found < best.?.start) {
                            best = .{ .start = found, .prefix = prefix };
                        }
                    }
                }

                const match = best orelse break;
                try out.appendSlice(allocator, prop.raw[cursor..match.start]);

                const id_start = match.start + match.prefix.len;
                const id_end = std.mem.indexOfPos(u8, prop.raw, id_start, "\"") orelse break;
                const old_id = prop.raw[id_start..id_end];

                try out.appendSlice(allocator, prop.raw[match.start..id_start]);
                if (remap.get(old_id)) |new_id| {
                    try out.appendSlice(allocator, new_id);
                    changed = true;
                } else {
                    try out.appendSlice(allocator, old_id);
                }
                try out.append(allocator, '"');
                cursor = id_end + 1;
            }

            if (!changed) continue;
            if (cursor < prop.raw.len) try out.appendSlice(allocator, prop.raw[cursor..]);

            allocator.free(section.properties.items[prop_index].raw);
            section.properties.items[prop_index].raw = try out.toOwnedSlice(allocator);
        }
    }
}

const ExtSortCtx = struct {
    doc: *const document.Document,
};

fn extResourceIdLessThan(ctx: ExtSortCtx, a_index: usize, b_index: usize) bool {
    const a_id = ctx.doc.sections.items[a_index].header.getString("id") orelse "";
    const b_id = ctx.doc.sections.items[b_index].header.getString("id") orelse "";
    return naturalLessThan(a_id, b_id);
}

fn sortResourceSections(allocator: std.mem.Allocator, doc: *document.Document) !void {
    var seen_sub = false;
    var needs_sort = false;
    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "sub_resource")) seen_sub = true;
        if (seen_sub and std.mem.eql(u8, section.header.name, "ext_resource")) {
            needs_sort = true;
            break;
        }
    }
    if (!needs_sort) return;

    var header: std.ArrayList(usize) = .empty;
    defer header.deinit(allocator);
    var ext: std.ArrayList(usize) = .empty;
    defer ext.deinit(allocator);
    var sub: std.ArrayList(usize) = .empty;
    defer sub.deinit(allocator);
    var rest: std.ArrayList(usize) = .empty;
    defer rest.deinit(allocator);

    for (doc.sections.items, 0..) |section, index| {
        const name = section.header.name;
        if (std.mem.eql(u8, name, "gd_scene") or std.mem.eql(u8, name, "gd_resource")) {
            try header.append(allocator, index);
        } else if (std.mem.eql(u8, name, "ext_resource")) {
            try ext.append(allocator, index);
        } else if (std.mem.eql(u8, name, "sub_resource")) {
            try sub.append(allocator, index);
        } else {
            try rest.append(allocator, index);
        }
    }

    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    try order.appendSlice(allocator, header.items);
    try order.appendSlice(allocator, ext.items);
    try order.appendSlice(allocator, sub.items);
    try order.appendSlice(allocator, rest.items);

    var reordered: std.ArrayList(document.Section) = .empty;
    try reordered.ensureTotalCapacity(allocator, doc.sections.items.len);
    for (order.items) |idx| try reordered.append(allocator, doc.sections.items[idx]);

    for (doc.sections.items) |*section| {
        section.* = document.Section{
            .line = 0,
            .header = tag.Tag{ .name = "", .fields = .{} },
            .properties = .empty,
        };
    }
    doc.sections.deinit(allocator);
    doc.sections = reordered;
}

fn sortExtResourceSections(allocator: std.mem.Allocator, doc: *document.Document) !void {
    var before: std.ArrayList(usize) = .empty;
    defer before.deinit(allocator);
    var ext: std.ArrayList(usize) = .empty;
    defer ext.deinit(allocator);
    var after: std.ArrayList(usize) = .empty;
    defer after.deinit(allocator);

    var phase: enum { before, ext, after } = .before;
    for (doc.sections.items, 0..) |section, index| {
        if (std.mem.eql(u8, section.header.name, "ext_resource")) {
            phase = .ext;
            try ext.append(allocator, index);
        } else switch (phase) {
            .before => try before.append(allocator, index),
            .ext => try after.append(allocator, index),
            .after => try after.append(allocator, index),
        }
    }

    if (ext.items.len < 2) return;

    const ctx = ExtSortCtx{ .doc = doc };
    std.mem.sort(usize, ext.items, ctx, extResourceIdLessThan);

    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    try order.appendSlice(allocator, before.items);
    try order.appendSlice(allocator, ext.items);
    try order.appendSlice(allocator, after.items);

    var reordered: std.ArrayList(document.Section) = .empty;
    try reordered.ensureTotalCapacity(allocator, doc.sections.items.len);

    for (order.items) |idx| {
        try reordered.append(allocator, doc.sections.items[idx]);
    }

    for (doc.sections.items) |*section| {
        section.* = document.Section{
            .line = 0,
            .header = tag.Tag{ .name = "", .fields = .{} },
            .properties = .empty,
        };
    }
    doc.sections.deinit(allocator);
    doc.sections = reordered;
}

pub fn updateLoadSteps(doc: *document.Document) void {
    var ext_count: usize = 0;
    var sub_count: usize = 0;

    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "ext_resource")) ext_count += 1;
        if (std.mem.eql(u8, section.header.name, "sub_resource")) sub_count += 1;
    }

    const load_steps: i64 = @intCast(ext_count + sub_count + 1);

    for (doc.sections.items) |*section| {
        if (std.mem.eql(u8, section.header.name, "gd_scene") or std.mem.eql(u8, section.header.name, "gd_resource")) {
            if (section.header.fields.getPtr("load_steps")) |value| {
                value.* = .{ .integer = load_steps };
            }
            return;
        }
    }
}

fn naturalLessThan(a: []const u8, b: []const u8) bool {
    var ai: usize = 0;
    var bi: usize = 0;
    while (ai < a.len and bi < b.len) {
        const ac = std.ascii.toLower(a[ai]);
        const bc = std.ascii.toLower(b[bi]);

        if (std.ascii.isDigit(ac) and std.ascii.isDigit(bc)) {
            const a_num = parseDigitRun(a, &ai);
            const b_num = parseDigitRun(b, &bi);
            if (a_num != b_num) return a_num < b_num;
            continue;
        }

        if (ac != bc) return ac < bc;
        ai += 1;
        bi += 1;
    }
    return a.len < b.len;
}

fn parseDigitRun(text: []const u8, index: *usize) u64 {
    var value: u64 = 0;
    while (index.* < text.len and std.ascii.isDigit(text[index.*])) {
        value = value * 10 + (text[index.*] - '0');
        index.* += 1;
    }
    return value;
}

fn recordExtResourceIds(allocator: std.mem.Allocator, doc: *document.Document, seed_path: []const u8, session: *id_session.Session) !void {
    _ = allocator;
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const ext_path = section.header.getString("path") orelse continue;
        const id = section.header.getString("id") orelse continue;
        try session.setExtId(session.referrers.allocator, seed_path, ext_path, id);
    }
}

fn assignNodeUniqueIds(allocator: std.mem.Allocator, doc: *document.Document, seed_path: []const u8) !void {
    node_id.resetNodeUniqueIdGenerator();
    node_id.seedNodeUniqueIdGeneratorFromPath(seed_path);

    var used = std.AutoHashMap(i32, void).init(allocator);
    defer used.deinit();

    var needs_assign: std.ArrayList(usize) = .empty;
    defer needs_assign.deinit(allocator);

    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "node")) continue;

        if (section.header.getInteger("unique_id")) |unique_id| {
            if (id_validate.validateNodeUniqueId(unique_id) == null) {
                const id: i32 = @intCast(unique_id);
                const gop = try used.getOrPut(id);
                if (gop.found_existing) {
                    try needs_assign.append(allocator, index);
                }
                continue;
            }
        }
        try needs_assign.append(allocator, index);
    }

    for (needs_assign.items) |index| {
        const new_id = try node_id.generateNodeUniqueId(&used);
        try used.put(new_id, {});
        try doc.sections.items[index].header.setIntegerField(allocator, "unique_id", new_id);
    }
}

test "uses id session cache for ext_resource ids" {
    const allocator = std.testing.allocator;
    var session = id_session.Session.init(allocator);
    defer session.deinit(allocator);
    try session.setExtId(allocator, "res://test.tscn", "res://a.gd", "1_cached");

    const source =
        \\[gd_scene format=3]
        \\[ext_resource type="Script" path="res://a.gd"]
        \\[node name="Root" type="Node"]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try prepareDocument(allocator, &doc, .{
        .seed_path = "res://test.tscn",
        .sort_ext_resources = false,
        .update_load_steps = false,
        .assign_node_unique_ids = false,
        .id_session = &session,
    });

    try std.testing.expectEqualStrings("1_cached", doc.sections.items[1].header.getString("id").?);
}

test "assigns node unique_id when missing" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[node name="Root" type="Node"]
        \\[node name="Child" type="Node" parent="Root"]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try prepareDocument(allocator, &doc, .{
        .seed_path = "res://test.tscn",
        .repair_ids = false,
        .sort_ext_resources = false,
        .update_load_steps = false,
    });

    const root_id = doc.sections.items[1].header.getInteger("unique_id").?;
    const child_id = doc.sections.items[2].header.getInteger("unique_id").?;
    try std.testing.expect(root_id > 0);
    try std.testing.expect(child_id > 0);
    try std.testing.expect(root_id != child_id);

    var doc2 = try document.parseBytes(allocator, source);
    defer doc2.deinit(allocator);
    try prepareDocument(allocator, &doc2, .{
        .seed_path = "res://test.tscn",
        .repair_ids = false,
        .sort_ext_resources = false,
        .update_load_steps = false,
    });
    try std.testing.expectEqual(root_id, doc2.sections.items[1].header.getInteger("unique_id").?);
    try std.testing.expectEqual(child_id, doc2.sections.items[2].header.getInteger("unique_id").?);
}

test "assigns missing ext_resource id deterministically" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[ext_resource type="Script" path="res://a.gd"]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try prepareDocument(allocator, &doc, .{ .seed_path = "res://test.tscn" });
    try std.testing.expectEqualStrings("1_mf4mk", doc.sections.items[1].header.getString("id").?);
    try std.testing.expectEqual(@as(i64, 2), doc.sections.items[0].header.getInteger("load_steps").?);
}

test "sorts ext_resource sections by id" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[ext_resource type="Script" path="res://b.gd" id="2_aaaaa"]
        \\[ext_resource type="Script" path="res://a.gd" id="1_zzzzz"]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try prepareDocument(allocator, &doc, .{ .seed_path = "res://test.tscn", .repair_ids = false });
    try std.testing.expectEqualStrings("1_zzzzz", doc.sections.items[1].header.getString("id").?);
    try std.testing.expectEqualStrings("2_aaaaa", doc.sections.items[2].header.getString("id").?);
}

test "remaps property references when duplicate ext id is repaired" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[ext_resource type="Script" path="res://a.gd" id="1_abcde"]
        \\[ext_resource type="Script" path="res://b.gd" id="1_abcde"]
        \\
        \\[node name="Root" type="Node"]
        \\script = ExtResource("1_abcde")
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try prepareDocument(allocator, &doc, .{ .seed_path = "res://test.tscn" });
    const first = doc.sections.items[1].header.getString("id").?;
    const second = doc.sections.items[2].header.getString("id").?;
    try std.testing.expect(!std.mem.eql(u8, first, second));
}
