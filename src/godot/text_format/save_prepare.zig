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
const property_sort = @import("property_sort.zig");

pub const SaveOptions = struct {
    /// Path used to seed `Resource::seed_scene_unique_id` (typically `res://…` or save target).
    seed_path: []const u8,
    repair_ids: bool = true,
    sort_ext_resources: bool = true,
    update_load_steps: bool = true,
    assign_node_unique_ids: bool = true,
    sort_node_sections: bool = true,
    /// Put each section's properties in the order Godot's save writes them.
    sort_properties: bool = true,
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
        try sortSubResourceSections(allocator, doc);
    }
    if (options.update_load_steps) {
        try updateLoadSteps(allocator, doc);
    }
    if (options.assign_node_unique_ids) {
        try assignNodeUniqueIds(allocator, doc, options.seed_path);
    }
    if (options.sort_node_sections) {
        try node_section_order.sortNodeSections(allocator, doc);
    }
    if (options.sort_properties) {
        try property_sort.sortDocument(allocator, doc);
    }
    if (options.id_session) |session| {
        try recordExtResourceIds(allocator, doc, options.seed_path, session);
    }
    if (options.godot_save_format) {
        try godot_format.applyGodotSaveFormat(allocator, doc);
    }
}

/// ExtResource and SubResource ids are separate namespaces: a file Godot
/// saved before the `Type_xxxxx` ids routinely has an ext_resource "1" and a
/// sub_resource "1". With one set for both, every write renamed the second,
/// and 132 of the 396 scenes in Godot's demo projects changed on a save.
fn assignSceneIds(allocator: std.mem.Allocator, doc: *document.Document, options: SaveOptions) !void {
    var used_ext = IdSet.init(allocator);
    defer freeIdSet(allocator, &used_ext);
    var used_sub = IdSet.init(allocator);
    defer freeIdSet(allocator, &used_sub);
    var ext_remap = Remap.init(allocator);
    defer freeRemap(allocator, &ext_remap);
    var sub_remap = Remap.init(allocator);
    defer freeRemap(allocator, &sub_remap);
    const used_ids = &used_ext;

    var ext_index: u32 = 1;
    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;

        const ext_path = section.header.getString("path");
        const existing = section.header.getString("id");

        var cached_id: ?[]const u8 = null;
        if (options.id_session) |session| {
            if (ext_path) |path| {
                if (session.getExtId(options.seed_path, path)) |cached| {
                    if (!used_ext.contains(cached)) cached_id = cached;
                }
            }
        }

        const new_id = if (cached_id) |cached|
            try allocator.dupe(u8, cached)
        else
            try resolveExtResourceId(allocator, existing, ext_index, used_ids);
        defer allocator.free(new_id);
        ext_index += 1;

        if (existing) |old_id| {
            if (!std.mem.eql(u8, old_id, new_id)) {
                try putRemap(allocator, &ext_remap, old_id, new_id);
            }
        }

        try section.header.setStringField(allocator, "id", new_id);
        const owned = try allocator.dupe(u8, new_id);
        const gop = try used_ext.getOrPut(owned);
        if (gop.found_existing) allocator.free(owned);
    }

    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;

        const type_name = section.header.getString("type") orelse "Resource";
        const existing = section.header.getString("id");
        const new_id = try resolveSubResourceId(allocator, type_name, existing, &used_sub);
        defer allocator.free(new_id);

        if (existing) |old_id| {
            if (!std.mem.eql(u8, old_id, new_id)) {
                try putRemap(allocator, &sub_remap, old_id, new_id);
            }
        }

        try section.header.setStringField(allocator, "id", new_id);
        const owned = try allocator.dupe(u8, new_id);
        const gop = try used_sub.getOrPut(owned);
        if (gop.found_existing) allocator.free(owned);
    }

    if (ext_remap.count() > 0 or sub_remap.count() > 0) {
        try applyIdRemap(allocator, doc, &ext_remap, &sub_remap);
    }
}

const IdSet = std.StringHashMap(void);
const Remap = std.StringHashMap([]const u8);

fn freeIdSet(allocator: std.mem.Allocator, set: *IdSet) void {
    var it = set.keyIterator();
    while (it.next()) |key| allocator.free(key.*);
    set.deinit();
}

fn freeRemap(allocator: std.mem.Allocator, remap: *Remap) void {
    var it = remap.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        allocator.free(entry.value_ptr.*);
    }
    remap.deinit();
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
        const prefix = idPrefix(id) orelse try allocator.print("{d}_", .{index});
        defer if (idPrefix(id) == null) allocator.free(prefix);
        return generateUniqueId(allocator, prefix, used);
    }
    const prefix = try allocator.print("{d}_", .{index});
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
        const prefix = idPrefix(id) orelse try allocator.print("{s}_", .{type_name});
        defer if (idPrefix(id) == null) allocator.free(prefix);
        return generateUniqueId(allocator, prefix, used);
    }
    const prefix = try allocator.print("{s}_", .{type_name});
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
        const id = try allocator.print("{s}{s}", .{ prefix, &suffix });
        if (!used.contains(id)) return id;
        allocator.free(id);
    }
}

fn applyIdRemap(allocator: std.mem.Allocator, doc: *document.Document, ext_remap: *const Remap, sub_remap: *const Remap) !void {
    const patterns = [_][]const u8{ "ExtResource(\"", "SubResource(\"" };

    for (doc.sections.items) |*section| {
        // A node's `instance=ExtResource("...")` names an ext_resource too.
        if (section.header.getRaw("instance")) |instance| {
            const prefix = "ExtResource(\"";
            if (std.mem.startsWith(u8, instance, prefix)) {
                const rest = instance[prefix.len..];
                if (std.mem.indexOfScalar(u8, rest, '"')) |end| {
                    if (ext_remap.get(rest[0..end])) |new_id| {
                        const text = try allocator.print("ExtResource(\"{s}\")", .{new_id});
                        defer allocator.free(text);
                        try section.header.setRawField(allocator, "instance", text);
                    }
                }
            }
        }
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
                const remap = if (std.mem.eql(u8, match.prefix, patterns[0])) ext_remap else sub_remap;
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

/// Put sub_resources in the order Godot's save reaches them: walking the
/// nodes in file order (or a .tres's [resource]), each node's properties in
/// order and each resource's sorted by name, a sub_resource is written after
/// the sub_resources it refers to.
/// godot-cli kept the order they were added, so a material added before a
/// second mesh sat where Godot's save does not put it (trial 46). One no
/// section refers to stays where it was, after the rest.
fn sortSubResourceSections(allocator: std.mem.Allocator, doc: *document.Document) !void {
    var slots: std.ArrayList(usize) = .empty;
    defer slots.deinit(allocator);
    var by_id: std.StringHashMapUnmanaged(usize) = .empty;
    defer by_id.deinit(allocator);
    for (doc.sections.items, 0..) |section, index| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
        try slots.append(allocator, index);
        if (section.header.getString("id")) |id| try by_id.put(allocator, id, index);
    }
    if (slots.items.len < 2) return;

    var order: std.ArrayList(usize) = .empty;
    defer order.deinit(allocator);
    var visited: std.AutoHashMapUnmanaged(usize, void) = .empty;
    defer visited.deinit(allocator);
    for (doc.sections.items) |*section| {
        const name = section.header.name;
        if (!std.mem.eql(u8, name, "node") and !std.mem.eql(u8, name, "resource")) continue;
        try visitSubReferences(allocator, doc, section, &by_id, &visited, &order);
    }
    for (slots.items) |index| {
        if (!visited.contains(index)) try order.append(allocator, index);
    }
    if (std.mem.eql(usize, order.items, slots.items)) return;

    var moved = try allocator.alloc(document.Section, order.items.len);
    defer allocator.free(moved);
    for (order.items, 0..) |index, i| moved[i] = doc.sections.items[index];
    for (slots.items, 0..) |slot, i| doc.sections.items[slot] = moved[i];
}

fn visitSubReferences(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    section: *const document.Section,
    by_id: *const std.StringHashMapUnmanaged(usize),
    visited: *std.AutoHashMapUnmanaged(usize, void),
    order: *std.ArrayList(usize),
) !void {
    const prefix = "SubResource(\"";
    // Inside a resource Godot walks the properties sorted by name
    // (ResourceFormatSaverTextInstance::_find_resources sorts the list); a
    // node's come in the order the scene packs them, which is file order.
    const props = try allocator.dupe(document.PropertyLine, section.properties.items);
    defer allocator.free(props);
    if (!std.mem.eql(u8, section.header.name, "node")) {
        std.mem.sort(document.PropertyLine, props, {}, struct {
            fn less(_: void, a: document.PropertyLine, b: document.PropertyLine) bool {
                return std.mem.lessThan(u8, keyOf(a.raw), keyOf(b.raw));
            }
            fn keyOf(raw: []const u8) []const u8 {
                return raw[0 .. std.mem.indexOf(u8, raw, " = ") orelse raw.len];
            }
        }.less);
    }
    for (props) |prop| {
        var cursor: usize = 0;
        while (std.mem.indexOfPos(u8, prop.raw, cursor, prefix)) |at| {
            const start = at + prefix.len;
            const end = std.mem.indexOfScalarPos(u8, prop.raw, start, '"') orelse break;
            cursor = end;
            const index = by_id.get(prop.raw[start..end]) orelse continue;
            if (visited.contains(index)) continue;
            try visited.put(allocator, index, {});
            try visitSubReferences(allocator, doc, &doc.sections.items[index], by_id, visited, order);
            try order.append(allocator, index);
        }
    }
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

/// Keeps an existing `load_steps` in step with the ext_resource and
/// sub_resource count, and drops it when nothing is left to count, since Godot
/// never writes `load_steps=1`.
pub fn updateLoadSteps(allocator: std.mem.Allocator, doc: *document.Document) !void {
    var ext_count: usize = 0;
    var sub_count: usize = 0;

    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "ext_resource")) ext_count += 1;
        if (std.mem.eql(u8, section.header.name, "sub_resource")) sub_count += 1;
    }

    const load_steps: i64 = @intCast(ext_count + sub_count + 1);

    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "gd_scene") and !std.mem.eql(u8, section.header.name, "gd_resource")) continue;
        if (load_steps <= 1) {
            section.header.removeField(allocator, "load_steps");
            return;
        }
        if (section.header.fields.getPtr("load_steps")) |value| {
            value.* = .{ .integer = load_steps };
        }
        // Never added when absent: Godot omits it for small scenes (a script
        // reference alone saves as `[gd_scene format=3]`), and the round-trip
        // fixtures hold it to that.
        return;
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

        // An override of a node inside an instance keeps the id that node
        // has in its own scene, repeated across copies, and one it lacks is
        // not this file's to invent.
        if (id_validate.isInstanceOverride(&section.header)) {
            if (section.header.getInteger("unique_id")) |unique_id| {
                if (id_validate.validateNodeUniqueId(unique_id) == null) try used.put(@intCast(unique_id), {});
            }
            continue;
        }

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
        try doc.sections.items[index].header.setUniqueIdField(allocator, new_id);
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

test "a scene Godot saved comes back from a save byte for byte" {
    // The shapes Godot's demo projects showed a save mangling or crashing on:
    // a multi-line text with blank, indented and `[`-led lines; an
    // ext_resource and a sub_resource both "1"; two copies of an instance
    // whose overrides repeat one unique_id; a node parented inside an
    // instance; groups; consecutive [editable] lines.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const writer = @import("writer.zig");
    const bytes = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, "test_fixtures/godot_saved/legacy_ids_and_overrides.tscn", allocator, .unlimited);

    var doc = try document.parseBytes(allocator, bytes);
    try std.testing.expectEqualStrings(bytes, try writer.writeDocument(allocator, &doc));

    try prepareDocument(allocator, &doc, .{ .seed_path = "res://legacy.tscn" });
    try std.testing.expectEqualStrings(bytes, try writer.writeDocument(allocator, &doc));

    const report = try id_validate.validateDocument(allocator, &doc, .{});
    for (report.issues.items) |issue| {
        std.debug.print("unexpected issue: {s}: {s}\n", .{ issue.kind, issue.message });
    }
    try std.testing.expectEqual(@as(usize, 0), report.issues.items.len);
}

test "sub_resources go in the order Godot's save reaches them" {
    // From Godot's soft_body_physics demo: inside a resource the save walks
    // properties sorted by name, so color_ramp's Gradient precedes noise's
    // FastNoiseLite; each resource follows what it refers to.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const writer = @import("writer.zig");
    var doc = try document.parseBytes(allocator,
        \\[gd_scene format=3]
        \\
        \\[sub_resource type="StandardMaterial3D" id="StandardMaterial3D_m"]
        \\albedo_texture = SubResource("NoiseTexture2D_t")
        \\
        \\[sub_resource type="NoiseTexture2D" id="NoiseTexture2D_t"]
        \\noise = SubResource("FastNoiseLite_n")
        \\color_ramp = SubResource("Gradient_g")
        \\
        \\[sub_resource type="FastNoiseLite" id="FastNoiseLite_n"]
        \\
        \\[sub_resource type="Gradient" id="Gradient_g"]
        \\
        \\[sub_resource type="BoxMesh" id="BoxMesh_unused"]
        \\
        \\[node name="Body" type="MeshInstance3D" unique_id=1]
        \\material_override = SubResource("StandardMaterial3D_m")
        \\
    );
    try sortSubResourceSections(allocator, &doc);
    const text = try writer.writeDocument(allocator, &doc);
    const g = std.mem.indexOf(u8, text, "Gradient_g\"]").?;
    const n = std.mem.indexOf(u8, text, "FastNoiseLite_n\"]").?;
    const t = std.mem.indexOf(u8, text, "NoiseTexture2D_t\"]").?;
    const m = std.mem.indexOf(u8, text, "StandardMaterial3D_m\"]").?;
    const unused = std.mem.indexOf(u8, text, "BoxMesh_unused\"]").?;
    try std.testing.expect(g < n and n < t and t < m and m < unused);
}
