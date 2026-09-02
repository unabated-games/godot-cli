//! Structured context for errors raised deep inside patch and intent code.
//!
//! Handlers return plain error values, and the CLI turns the error name into
//! `failure.kind`. That loses the one thing an agent needs to self-correct:
//! which field, which value, and what would have been accepted. Code that
//! raises one of those errors records the context here first, and the CLI
//! attaches it as `failure.details`.

const std = @import("std");

pub const Detail = struct {
    /// The patch op or intent recipe being applied, when known.
    op: ?[]const u8 = null,
    field: ?[]const u8 = null,
    value: ?[]const u8 = null,
    hint: ?[]const u8 = null,
};

threadlocal var last: ?Detail = null;
threadlocal var current_op: ?[]const u8 = null;

/// Set by the op dispatcher so field errors can name the op without every
/// helper taking it as a parameter.
pub fn setCurrentOp(op: ?[]const u8) void {
    current_op = op;
}

pub fn record(detail: Detail) void {
    var with_op = detail;
    if (with_op.op == null) with_op.op = current_op;
    last = with_op;
}

pub fn clear() void {
    last = null;
    current_op = null;
}

/// Human-readable message for a failure kind, and the recorded context as a
/// JSON object. Strings are copied into `allocator`, since the recorded slices
/// may point into an arena the handler has already released.
pub fn takeJson(allocator: std.mem.Allocator) !?std.json.ObjectMap {
    const detail = last orelse return null;
    last = null;

    var map: std.json.ObjectMap = .{};
    if (detail.op) |op| try map.put(allocator, "op", .{ .string = try allocator.dupe(u8, op) });
    if (detail.field) |field| try map.put(allocator, "field", .{ .string = try allocator.dupe(u8, field) });
    if (detail.value) |value| try map.put(allocator, "value", .{ .string = try allocator.dupe(u8, value) });
    if (detail.hint) |hint| try map.put(allocator, "hint", .{ .string = try allocator.dupe(u8, hint) });
    return map;
}

test "record fills in the current op" {
    setCurrentOp("node_add");
    record(.{ .field = "parent" });
    const json = (try takeJson(std.testing.allocator)).?;
    defer {
        var mutable = json;
        for (mutable.values()) |v| std.testing.allocator.free(v.string);
        mutable.deinit(std.testing.allocator);
    }
    try std.testing.expectEqualStrings("node_add", json.get("op").?.string);
    try std.testing.expectEqualStrings("parent", json.get("field").?.string);
    clear();
}
