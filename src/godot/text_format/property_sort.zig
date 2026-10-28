//! Put a section's properties in the order Godot's save writes them.
//!
//! A save walks `get_property_list`: the base class's registered properties
//! first, each class's in the order it registers them, a Control's theme
//! overrides after Control's own, then `script`, the script's variables, and
//! metadata last. godot-cli used to keep properties in the order they were
//! given, so the editor's next save reordered them (MeshInstance3D's `mesh`
//! before Node3D's `transform`). A section holding a property this cannot
//! place keeps its order, so nothing is guessed.

const std = @import("std");
const document = @import("document.zig");
const class_info = @import("../class_info.zig");
const property_order = @import("../property_order.zig");

fn ownProperties(class: []const u8) ?[]const []const u8 {
    const entries = &property_order.classes;
    var low: usize = 0;
    var high: usize = entries.len;
    while (low < high) {
        const mid = (low + high) / 2;
        switch (std.mem.order(u8, entries[mid].class, class)) {
            .eq => return entries[mid].properties,
            .lt => low = mid + 1,
            .gt => high = mid,
        }
    }
    return null;
}

fn propertyName(raw: []const u8) ?[]const u8 {
    const eq = std.mem.indexOf(u8, raw, " = ") orelse return null;
    return raw[0..eq];
}

/// Sort the properties of every node, sub_resource and resource section whose
/// type the tables know.
pub fn sortDocument(allocator: std.mem.Allocator, doc: *document.Document) !void {
    for (doc.sections.items) |*section| {
        const name = section.header.name;
        if (!std.mem.eql(u8, name, "node") and !std.mem.eql(u8, name, "sub_resource") and !std.mem.eql(u8, name, "resource")) continue;
        if (section.properties.items.len < 2) continue;
        // A [resource] section's type is on the file header.
        const class = if (std.mem.eql(u8, name, "resource"))
            (if (doc.sections.items.len > 0) doc.sections.items[0].header.getString("type") else null)
        else
            section.header.getString("type");
        try sortSection(allocator, section, class orelse continue);
    }
}

const Ranked = struct { rank: usize, index: usize, line: document.PropertyLine };

fn lessThan(_: void, a: Ranked, b: Ranked) bool {
    if (a.rank != b.rank) return a.rank < b.rank;
    return a.index < b.index;
}

fn sortSection(allocator: std.mem.Allocator, section: *document.Section, class: []const u8) !void {
    // The class and its ancestors, base first.
    var chain: std.ArrayList([]const u8) = .empty;
    defer chain.deinit(allocator);
    var current = class;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const info = class_info.findClass(current) orelse return;
        try chain.insert(allocator, 0, current);
        if (info.inherits.len == 0) break;
        current = info.inherits;
    }

    var ranks: std.StringHashMapUnmanaged(usize) = .empty;
    defer ranks.deinit(allocator);
    var next: usize = 0;
    var theme_rank: ?usize = null;
    for (chain.items) |level| {
        const own = ownProperties(level) orelse return;
        for (own) |property| {
            const entry = try ranks.getOrPut(allocator, property);
            if (!entry.found_existing) {
                entry.value_ptr.* = next;
                next += 1;
            }
        }
        // Control::_get_property_list adds the theme overrides after
        // Control's registered properties, before any subclass's.
        if (std.mem.eql(u8, level, "Control")) {
            theme_rank = next;
            next += 1;
        }
    }
    const script_rank = next;
    const script_vars_rank = next + 1;
    const metadata_rank = next + 2;

    var has_script = false;
    for (section.properties.items) |line| {
        if (propertyName(line.raw)) |key| if (std.mem.eql(u8, key, "script")) {
            has_script = true;
        };
    }

    var ranked = try allocator.alloc(Ranked, section.properties.items.len);
    defer allocator.free(ranked);
    var already_sorted = true;
    for (section.properties.items, 0..) |line, index| {
        const key = propertyName(line.raw) orelse return;
        const rank = if (ranks.get(key)) |r|
            r
        else if (std.mem.startsWith(u8, key, "theme_override_") and theme_rank != null)
            theme_rank.?
        else if (std.mem.eql(u8, key, "script"))
            script_rank
        else if (std.mem.startsWith(u8, key, "metadata/"))
            metadata_rank
        else if (has_script and std.mem.indexOfScalar(u8, key, '/') == null)
            script_vars_rank
        else
            return; // a property the tables cannot place: leave the order alone
        ranked[index] = .{ .rank = rank, .index = index, .line = line };
        if (index > 0 and ranked[index - 1].rank > rank) already_sorted = false;
    }
    if (already_sorted) return;
    std.mem.sort(Ranked, ranked, {}, lessThan);
    for (ranked, 0..) |item, index| section.properties.items[index] = item.line;
}

test "a node's properties go in the editor's order, and an unknown one leaves them be" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    var doc = try document.parseBytes(allocator,
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node3D"]
        \\
        \\[node name="Box" type="MeshInstance3D" parent="."]
        \\mesh = SubResource("BoxMesh_a")
        \\metadata/note = "x"
        \\transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 6, 0, -4)
        \\
        \\[node name="Score" type="Label" parent="."]
        \\text = "0"
        \\theme_override_font_sizes/font_size = 24
        \\layout_mode = 0
        \\
        \\[node name="Odd" type="MeshInstance3D" parent="."]
        \\surface_material_override/0 = SubResource("M")
        \\transform = Transform3D(1, 0, 0, 0, 1, 0, 0, 0, 1, 1, 0, 0)
        \\mesh = SubResource("BoxMesh_a")
        \\
    );
    try sortDocument(allocator, &doc);
    const box = doc.sections.items[2].properties.items;
    try std.testing.expectEqualStrings("transform", propertyName(box[0].raw).?);
    try std.testing.expectEqualStrings("mesh", propertyName(box[1].raw).?);
    try std.testing.expectEqualStrings("metadata/note", propertyName(box[2].raw).?);
    const score = doc.sections.items[3].properties.items;
    try std.testing.expectEqualStrings("layout_mode", propertyName(score[0].raw).?);
    try std.testing.expectEqualStrings("theme_override_font_sizes/font_size", propertyName(score[1].raw).?);
    try std.testing.expectEqualStrings("text", propertyName(score[2].raw).?);
    // surface_material_override/0 is MeshInstance3D's own, added at run
    // time; the table cannot place it, so the given order stands.
    const odd = doc.sections.items[4].properties.items;
    try std.testing.expectEqualStrings("surface_material_override/0", propertyName(odd[0].raw).?);
}
