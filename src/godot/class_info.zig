//! Lookups over the generated class table: what type a property has on a
//! class, and whether a class declares a signal. Both walk the inheritance
//! chain, since `text` is declared on Button and `visible` on CanvasItem.
//!
//! Every lookup is conservative on purpose. A class the table does not carry
//! (a script class, or one from a newer engine) and a property it does not
//! declare (a `theme_override_*` entry, a script's exported variable, a
//! `metadata/*` key) both answer "no opinion" rather than "wrong", because a
//! false report on a correct scene costs more than a missed one.

const std = @import("std");
const table = @import("class_table.zig");

pub const godot_version = table.godot_version;

pub fn findClass(name: []const u8) ?table.Class {
    // The table is sorted by name, which is what the generator guarantees.
    var low: usize = 0;
    var high: usize = table.classes.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        switch (std.mem.order(u8, table.classes[mid].name, name)) {
            .lt => low = mid + 1,
            .gt => high = mid,
            .eq => return table.classes[mid],
        }
    }
    return null;
}

/// The property as the class or one of its ancestors declares it.
pub fn findProperty(class_name: []const u8, property: []const u8) ?table.Property {
    var current = class_name;
    // Object -> Node -> ... is a dozen deep at most; the bound only stops a
    // cycle a hand-edited table could introduce.
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const class = findClass(current) orelse return null;
        for (class.properties) |candidate| {
            if (std.mem.eql(u8, candidate.name, property)) return candidate;
        }
        if (class.inherits.len == 0) return null;
        current = class.inherits;
    }
    return null;
}

/// Whether the class or an ancestor declares the signal. Null when the class
/// is not in the table at all, which callers report differently from false.
pub fn hasSignal(class_name: []const u8, signal: []const u8) ?bool {
    if (findClass(class_name) == null) return null;
    var current = class_name;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const class = findClass(current) orelse return false;
        for (class.signals) |candidate| {
            if (std.mem.eql(u8, candidate, signal)) return true;
        }
        if (class.inherits.len == 0) return false;
        current = class.inherits;
    }
    return false;
}

/// Whether the class is the named one or descends from it. Replaces the hand
/// written class lists the validator used to carry, which named fifty of the
/// two hundred and sixty Node classes.
pub fn descendsFrom(class_name: []const u8, ancestor: []const u8) bool {
    var current = class_name;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        if (std.mem.eql(u8, current, ancestor)) return true;
        const class = findClass(current) orelse return false;
        if (class.inherits.len == 0) return false;
        current = class.inherits;
    }
    return false;
}

/// Whether a value that parsed as `kind` is acceptable for the property.
/// A property whose type carries no check accepts anything.
pub fn kindFits(property: table.Property, kind: []const u8) bool {
    if (property.kinds.len == 0) return true;
    for (property.kinds) |accepted| {
        if (std.mem.eql(u8, accepted, kind)) return true;
    }
    return false;
}

/// Every signal the class and its ancestors declare, for a failure message
/// that can suggest what was meant. Caller owns the slice.
pub fn collectSignals(allocator: std.mem.Allocator, class_name: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer out.deinit(allocator);
    var current = class_name;
    var hops: usize = 0;
    while (hops < 64) : (hops += 1) {
        const class = findClass(current) orelse break;
        for (class.signals) |signal| try out.append(allocator, signal);
        if (class.inherits.len == 0) break;
        current = class.inherits;
    }
    return out.toOwnedSlice(allocator);
}

test "properties resolve through the inheritance chain" {
    // Declared on Button itself.
    const text = findProperty("Button", "text").?;
    try std.testing.expectEqualStrings("String", text.type_name);
    // Declared on Control, four classes up.
    const anchor = findProperty("Button", "anchor_right").?;
    try std.testing.expectEqualStrings("float", anchor.type_name);
    // Declared on CanvasItem.
    const visible = findProperty("Button", "visible").?;
    try std.testing.expectEqualStrings("bool", visible.type_name);
    // Not a property of anything in the chain: no opinion.
    try std.testing.expect(findProperty("Button", "theme_override_styles/normal") == null);
    try std.testing.expect(findProperty("NotAGodotClass", "visible") == null);
}

test "a float property takes an integer literal, a bool does not" {
    const anchor = findProperty("Control", "anchor_right").?;
    try std.testing.expect(kindFits(anchor, "float"));
    try std.testing.expect(kindFits(anchor, "integer"));
    try std.testing.expect(!kindFits(anchor, "vector2"));

    const visible = findProperty("Node2D", "visible").?;
    try std.testing.expect(kindFits(visible, "bool"));
    try std.testing.expect(!kindFits(visible, "vector2"));
    try std.testing.expect(!kindFits(visible, "integer"));

    // A resource property takes a reference or null, not a number.
    const texture = findProperty("Sprite2D", "texture").?;
    try std.testing.expect(kindFits(texture, "ext_resource"));
    try std.testing.expect(kindFits(texture, "sub_resource"));
    try std.testing.expect(kindFits(texture, "null"));
    try std.testing.expect(!kindFits(texture, "integer"));
}

test "signals resolve through the chain, and an unknown class has no opinion" {
    try std.testing.expectEqual(@as(?bool, true), hasSignal("Button", "pressed"));
    try std.testing.expectEqual(@as(?bool, true), hasSignal("Button", "mouse_entered"));
    try std.testing.expectEqual(@as(?bool, true), hasSignal("Button", "tree_exited"));
    try std.testing.expectEqual(@as(?bool, false), hasSignal("Button", "pressd"));
    try std.testing.expectEqual(@as(?bool, null), hasSignal("MyScriptClass", "anything"));
}

test "descendsFrom covers every class, not a hand written list" {
    try std.testing.expect(descendsFrom("Button", "Control"));
    try std.testing.expect(descendsFrom("VBoxContainer", "Control"));
    // Not in the validator's old hand written list.
    try std.testing.expect(descendsFrom("OptionButton", "Control"));
    try std.testing.expect(descendsFrom("TextureProgressBar", "Control"));
    try std.testing.expect(descendsFrom("Sprite2D", "Node2D"));
    try std.testing.expect(descendsFrom("Node2D", "Node2D"));
    try std.testing.expect(!descendsFrom("Sprite2D", "Control"));
    try std.testing.expect(!descendsFrom("Node3D", "Node2D"));
    try std.testing.expect(!descendsFrom("SomeScriptClass", "Control"));
}
