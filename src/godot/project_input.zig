//! Input Map helpers for `project.godot` `[input]` section.

const std = @import("std");
const project_godot = @import("project_godot.zig");
const variant = @import("variant/root.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentField,
    UnknownKey,
    UnknownJoypadButton,
    UnknownJoypadAxis,
    InvalidEvent,
} || project_godot.Error;

pub const ActionInfo = struct {
    name: []const u8,
    deadzone: f64,
    event_count: usize,

    pub fn deinit(self: *const ActionInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

pub const ApplyResult = struct {
    applied_actions: []const []const u8,
    replaced_count: usize,
    added_count: usize,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.applied_actions) |name| allocator.free(name);
        allocator.free(self.applied_actions);
    }
};

pub fn listActions(allocator: std.mem.Allocator, section: *const project_godot.Section) Error![]ActionInfo {
    var out: std.ArrayList(ActionInfo) = .empty;
    errdefer {
        for (out.items) |*item| item.deinit(allocator);
        out.deinit(allocator);
    }

    for (section.entries.items) |entry| {
        const deadzone = parseDeadzone(entry.value) orelse 0.5;
        const event_count = countOccurrences(entry.value, "Object(");
        try out.append(allocator, .{
            .name = try allocator.dupe(u8, entry.key),
            .deadzone = deadzone,
            .event_count = event_count,
        });
    }

    return try out.toOwnedSlice(allocator);
}

pub fn applyIntentJson(
    allocator: std.mem.Allocator,
    doc: *project_godot.Document,
    intent_json: []const u8,
) Error!ApplyResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, intent_json, .{}) catch return error.InvalidIntent;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidIntent;
    const actions_value = root.object.get("actions") orelse return error.MissingIntentField;
    if (actions_value != .array) return error.InvalidIntent;

    const input = try doc.ensureSection(allocator, "input");
    var applied: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (applied.items) |name| allocator.free(name);
        applied.deinit(allocator);
    }

    var replaced: usize = 0;
    var added: usize = 0;

    for (actions_value.array.items) |*action_value| {
        if (action_value.* != .object) return error.InvalidIntent;
        const action = action_value.object;

        const name_value = action.get("name") orelse return error.MissingIntentField;
        if (name_value != .string or name_value.string.len == 0) return error.InvalidIntent;
        const action_name = name_value.string;

        const deadzone = if (action.get("deadzone")) |dz|
            switch (dz) {
                .float => |f| f,
                .integer => |n| @as(f64, @floatFromInt(n)),
                else => return error.InvalidIntent,
            }
        else
            0.5;

        const events_value = action.get("events") orelse return error.MissingIntentField;
        if (events_value != .array) return error.InvalidIntent;

        var event_strings: std.ArrayList([]const u8) = .empty;
        defer {
            for (event_strings.items) |text| allocator.free(text);
            event_strings.deinit(allocator);
        }

        for (events_value.array.items) |*event_value| {
            if (event_value.* != .object) return error.InvalidIntent;
            const event_text = try formatEventFromJson(allocator, event_value.object);
            try event_strings.append(allocator, event_text);
        }

        const block = try formatActionBlock(allocator, deadzone, event_strings.items);
        const existed = input.findEntry(action_name) != null;
        try input.setEntry(allocator, action_name, block);
        allocator.free(block);
        try applied.append(allocator, try allocator.dupe(u8, action_name));
        if (existed) replaced += 1 else added += 1;
    }

    return .{
        .applied_actions = try applied.toOwnedSlice(allocator),
        .replaced_count = replaced,
        .added_count = added,
    };
}

pub fn validateInputSection(allocator: std.mem.Allocator, section: *const project_godot.Section) Error!usize {
    var issue_count: usize = 0;
    for (section.entries.items) |entry| {
        if (parseDeadzone(entry.value) == null) issue_count += 1;
        var index: usize = 0;
        while (std.mem.indexOfPos(u8, entry.value, index, "Object(")) |start| {
            const end = findObjectEnd(entry.value, start) orelse {
                issue_count += 1;
                break;
            };
            const object_text = entry.value[start..end];
            const parsed = variant.parse.parsePropertyValue(allocator, object_text) catch {
                issue_count += 1;
                index = end;
                continue;
            };
            parsed.deinit(allocator);
            index = end;
        }
    }
    return issue_count;
}

fn parseDeadzone(value: []const u8) ?f64 {
    const needle = "\"deadzone\":";
    const start = std.mem.indexOf(u8, value, needle) orelse return null;
    const rest = std.mem.trim(u8, value[start + needle.len ..], &std.ascii.whitespace);
    const end_comma = std.mem.indexOfScalar(u8, rest, ',') orelse rest.len;
    const token = std.mem.trim(u8, rest[0..end_comma], &std.ascii.whitespace);
    return std.fmt.parseFloat(f64, token) catch null;
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var index: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, index, needle)) |found| {
        total += 1;
        index = found + needle.len;
    }
    return total;
}

fn findObjectEnd(text: []const u8, start: usize) ?usize {
    const rel_open = std.mem.indexOf(u8, text[start..], "(") orelse return null;
    var i = start + rel_open + 1;
    var depth: i32 = 1;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
    }
    return null;
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) Error!void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn formatActionBlock(allocator: std.mem.Allocator, deadzone: f64, events: []const []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "{\n");
    try appendFmt(allocator, &out, "\"deadzone\": {d},\n", .{deadzone});
    try out.appendSlice(allocator, "\"events\": [");
    for (events, 0..) |event, index| {
        if (index > 0) try out.appendSlice(allocator, ", ");
        try out.appendSlice(allocator, event);
    }
    try out.appendSlice(allocator, "]\n}");
    return try out.toOwnedSlice(allocator);
}

fn formatEventFromJson(allocator: std.mem.Allocator, event: std.json.ObjectMap) Error![]const u8 {
    const type_value = event.get("type") orelse return error.MissingIntentField;
    if (type_value != .string) return error.InvalidIntent;

    if (std.mem.eql(u8, type_value.string, "key")) {
        const keycode = if (event.get("keycode")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else return error.MissingIntentField;
        const physical = readBool(event.get("physical")) orelse true;
        const codes = try resolveKey(keycode, physical);
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventKey,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":-1,\"window_id\":0,\"alt_pressed\":false,\"shift_pressed\":false,\"ctrl_pressed\":false,\"meta_pressed\":false,\"pressed\":false,\"keycode\":{d},\"physical_keycode\":{d},\"key_label\":0,\"unicode\":{d},\"location\":0,\"echo\":false,\"script\":null)",
            .{ codes.keycode, codes.physical_keycode, codes.unicode },
        );
    }

    if (std.mem.eql(u8, type_value.string, "joypad_button")) {
        const button = if (event.get("button")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else return error.MissingIntentField;
        const button_index = try resolveJoypadButton(button);
        const pressed = readBool(event.get("pressed")) orelse false;
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventJoypadButton,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":-1,\"button_index\":{d},\"pressure\":0.0,\"pressed\":{s},\"script\":null)",
            .{ button_index, if (pressed) "true" else "false" },
        );
    }

    if (std.mem.eql(u8, type_value.string, "joypad_motion")) {
        const axis = if (event.get("axis")) |v| blk: {
            if (v == .string) break :blk try resolveJoypadAxis(v.string);
            if (v == .integer) break :blk @as(i32, @intCast(v.integer));
            return error.InvalidIntent;
        } else return error.MissingIntentField;
        const axis_value = if (event.get("axis_value")) |v| blk: {
            switch (v) {
                .float => |f| break :blk f,
                .integer => |n| break :blk @as(f64, @floatFromInt(n)),
                else => return error.InvalidIntent,
            }
        } else return error.MissingIntentField;
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventJoypadMotion,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":-1,\"axis\":{d},\"axis_value\":{d},\"script\":null)",
            .{ axis, axis_value },
        );
    }

    return error.InvalidEvent;
}

const KeyCodes = struct {
    keycode: i32,
    physical_keycode: i32,
    unicode: i32,
};

fn resolveKey(name: []const u8, physical: bool) Error!KeyCodes {
    if (std.mem.eql(u8, name, "SPACE") or std.mem.eql(u8, name, "Space")) {
        return .{ .keycode = 32, .physical_keycode = 32, .unicode = 32 };
    }
    if (std.mem.startsWith(u8, name, "KEY_")) {
        const letter = name["KEY_".len..];
        if (letter.len == 1) {
            const upper = std.ascii.toUpper(letter[0]);
            const code: i32 = @intCast(upper);
            if (physical) return .{ .keycode = 0, .physical_keycode = code, .unicode = @intCast(std.ascii.toLower(upper)) };
            return .{ .keycode = code, .physical_keycode = 0, .unicode = @intCast(std.ascii.toLower(upper)) };
        }
    }
    if (name.len == 1) {
        const upper = std.ascii.toUpper(name[0]);
        const code: i32 = @intCast(upper);
        if (physical) return .{ .keycode = 0, .physical_keycode = code, .unicode = @intCast(std.ascii.toLower(upper)) };
        return .{ .keycode = code, .physical_keycode = 0, .unicode = @intCast(std.ascii.toLower(upper)) };
    }
    if (std.mem.eql(u8, name, "UP") or std.mem.eql(u8, name, "ArrowUp")) return .{ .keycode = 4194320, .physical_keycode = 4194320, .unicode = 0 };
    if (std.mem.eql(u8, name, "DOWN") or std.mem.eql(u8, name, "ArrowDown")) return .{ .keycode = 4194322, .physical_keycode = 4194322, .unicode = 0 };
    if (std.mem.eql(u8, name, "LEFT") or std.mem.eql(u8, name, "ArrowLeft")) return .{ .keycode = 4194319, .physical_keycode = 4194319, .unicode = 0 };
    if (std.mem.eql(u8, name, "RIGHT") or std.mem.eql(u8, name, "ArrowRight")) return .{ .keycode = 4194321, .physical_keycode = 4194321, .unicode = 0 };
    return error.UnknownKey;
}

fn resolveJoypadButton(name: []const u8) Error!i32 {
    if (std.mem.eql(u8, name, "a") or std.mem.eql(u8, name, "A") or std.mem.eql(u8, name, "south")) return 0;
    if (std.mem.eql(u8, name, "b") or std.mem.eql(u8, name, "B") or std.mem.eql(u8, name, "east")) return 1;
    if (std.mem.eql(u8, name, "x") or std.mem.eql(u8, name, "X") or std.mem.eql(u8, name, "west")) return 2;
    if (std.mem.eql(u8, name, "y") or std.mem.eql(u8, name, "Y") or std.mem.eql(u8, name, "north")) return 3;
    if (std.mem.eql(u8, name, "dpad_up")) return 11;
    if (std.mem.eql(u8, name, "dpad_down")) return 12;
    if (std.mem.eql(u8, name, "dpad_left")) return 13;
    if (std.mem.eql(u8, name, "dpad_right")) return 14;
    return error.UnknownJoypadButton;
}

fn resolveJoypadAxis(name: []const u8) Error!i32 {
    if (std.mem.eql(u8, name, "left_x") or std.mem.eql(u8, name, "LX")) return 0;
    if (std.mem.eql(u8, name, "left_y") or std.mem.eql(u8, name, "LY")) return 1;
    if (std.mem.eql(u8, name, "right_x") or std.mem.eql(u8, name, "RX")) return 2;
    if (std.mem.eql(u8, name, "right_y") or std.mem.eql(u8, name, "RY")) return 3;
    return error.UnknownJoypadAxis;
}

fn readBool(value: ?std.json.Value) ?bool {
    const v = value orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

test "format wasd key event" {
    const allocator = std.testing.allocator;
    const intent =
        \\{ "type": "key", "keycode": "A", "physical": true }
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, intent, .{});
    defer parsed.deinit();
    const event_obj = parsed.value.object;

    const text = try formatEventFromJson(allocator, event_obj);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "InputEventKey") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "physical_keycode\":65") != null);
}

test "apply intent adds input actions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, "test_fixtures/project/project.godot", allocator, .unlimited) catch return error.TestExpectedEqual;
    defer allocator.free(bytes);
    var doc = try project_godot.parseBytes(allocator, bytes);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "actions": [
        \\    {
        \\      "name": "move_up",
        \\      "events": [
        \\        { "type": "key", "keycode": "W", "physical": true },
        \\        { "type": "joypad_motion", "axis": "left_y", "axis_value": -1.0 }
        \\      ]
        \\    }
        \\  ]
        \\}
    ;

    var result = try applyIntentJson(allocator, &doc, intent);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.added_count);
    const input = doc.sectionMut("input").?;
    try std.testing.expect(input.findEntry("move_up") != null);
}
