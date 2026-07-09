//! JSON helpers for unified `project apply`.

const std = @import("std");

pub const Error = error{
    OutOfMemory,
};

pub fn valueToJson(allocator: std.mem.Allocator, value: std.json.Value) Error![]const u8 {
    return try std.json.Stringify.valueAlloc(allocator, value, .{});
}

test "roundtrip object to json" {
    const allocator = std.testing.allocator;
    var obj: std.json.ObjectMap = .{};
    defer obj.deinit(allocator);
    try obj.put(allocator, "actions", .{ .array = std.json.Array.init(allocator) });
    const text = try valueToJson(allocator, .{ .object = obj });
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "actions") != null);
}
