//! Input Map helpers for `project.godot` `[input]` section.

const std = @import("std");
const project_godot = @import("project_godot.zig");
const variant = @import("variant/root.zig");
const error_details = @import("error_details.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentField,
    UnknownKey,
    UnknownJoypadButton,
    UnknownMouseButton,
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
        const physical = readBool(event.get("physical")) orelse true;
        const codes = if (event.get("keycode")) |v| blk: {
            if (v == .string) break :blk try resolveKey(v.string, physical);
            // A raw Godot keycode, so a key with no name here is still
            // reachable, the same escape hatch axis and button have.
            if (v == .integer) {
                const code: i32 = @intCast(v.integer);
                break :blk if (physical)
                    KeyCodes{ .keycode = 0, .physical_keycode = code, .unicode = 0 }
                else
                    KeyCodes{ .keycode = code, .physical_keycode = 0, .unicode = 0 };
            }
            error_details.record(.{ .field = "keycode", .hint = "a key name or a Godot keycode number; " ++ key_names });
            return error.InvalidIntent;
        } else {
            error_details.record(.{ .field = "keycode", .hint = key_names });
            return error.MissingIntentField;
        };
        // Modifiers, so Ctrl+S and Shift+Tab are expressible; Godot stores
        // them as flags on the event next to the keycode.
        const alt = readBool(event.get("alt")) orelse false;
        const shift = readBool(event.get("shift")) orelse false;
        const ctrl = readBool(event.get("ctrl")) orelse false;
        const meta = readBool(event.get("meta")) orelse false;
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventKey,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":{d},\"window_id\":0,\"alt_pressed\":{s},\"shift_pressed\":{s},\"ctrl_pressed\":{s},\"meta_pressed\":{s},\"pressed\":false,\"keycode\":{d},\"physical_keycode\":{d},\"key_label\":0,\"unicode\":{d},\"location\":0,\"echo\":false,\"script\":null)",
            .{
                readDevice(event),
                if (alt) "true" else "false",
                if (shift) "true" else "false",
                if (ctrl) "true" else "false",
                if (meta) "true" else "false",
                codes.keycode,
                codes.physical_keycode,
                codes.unicode,
            },
        );
    }

    if (std.mem.eql(u8, type_value.string, "mouse_button")) {
        const button_index = if (event.get("button")) |v| blk: {
            if (v == .string) break :blk try resolveMouseButton(v.string);
            if (v == .integer) break :blk @as(i32, @intCast(v.integer));
            error_details.record(.{ .field = "button", .hint = "a name or a MouseButton number; " ++ mouse_button_names });
            return error.InvalidIntent;
        } else {
            error_details.record(.{ .field = "button", .hint = mouse_button_names });
            return error.MissingIntentField;
        };
        const alt = readBool(event.get("alt")) orelse false;
        const shift = readBool(event.get("shift")) orelse false;
        const ctrl = readBool(event.get("ctrl")) orelse false;
        const meta = readBool(event.get("meta")) orelse false;
        // Property order and defaults taken from Godot's own var_to_str of an
        // InputEventMouseButton; device -1 is what the editor stores for an
        // action ("All Devices").
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventMouseButton,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":{d},\"window_id\":0,\"alt_pressed\":{s},\"shift_pressed\":{s},\"ctrl_pressed\":{s},\"meta_pressed\":{s},\"button_mask\":0,\"position\":Vector2(0, 0),\"global_position\":Vector2(0, 0),\"factor\":1.0,\"button_index\":{d},\"canceled\":false,\"pressed\":false,\"double_click\":false,\"script\":null)",
            .{
                readDevice(event),
                if (alt) "true" else "false",
                if (shift) "true" else "false",
                if (ctrl) "true" else "false",
                if (meta) "true" else "false",
                button_index,
            },
        );
    }

    if (std.mem.eql(u8, type_value.string, "joypad_button")) {
        const button_index = if (event.get("button")) |v| blk: {
            if (v == .string) break :blk try resolveJoypadButton(v.string);
            // A JoyButton number, the same escape hatch `axis` has, for the
            // controller-specific buttons past the named ones.
            if (v == .integer) break :blk @as(i32, @intCast(v.integer));
            error_details.record(.{ .field = "button", .hint = "a name or a JoyButton number; " ++ joypad_button_names });
            return error.InvalidIntent;
        } else {
            error_details.record(.{ .field = "button", .hint = joypad_button_names });
            return error.MissingIntentField;
        };
        const pressed = readBool(event.get("pressed")) orelse false;
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventJoypadButton,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":{d},\"button_index\":{d},\"pressure\":0.0,\"pressed\":{s},\"script\":null)",
            .{ readDevice(event), button_index, if (pressed) "true" else "false" },
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
        // axis_value is a float property, and Godot's VariantWriter appends
        // .0 to a whole float; without this a re-save in the editor rewrites
        // every joypad binding godot-cli wrote.
        const axis_text = variant.value.formatScalarFloat(allocator, axis_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidIntent,
        };
        defer allocator.free(axis_text);
        return try std.fmt.allocPrint(
            allocator,
            "Object(InputEventJoypadMotion,\"resource_local_to_scene\":false,\"resource_name\":\"\",\"device\":{d},\"axis\":{d},\"axis_value\":{s},\"script\":null)",
            .{ readDevice(event), axis, axis_text },
        );
    }

    error_details.record(.{ .field = "type", .value = type_value.string, .hint = "event types: key, mouse_button, joypad_button, joypad_motion" });
    return error.InvalidEvent;
}

const KeyCodes = struct {
    keycode: i32,
    physical_keycode: i32,
    unicode: i32,
};

/// Godot packs its non-printable keys into the top bits: `SPECIAL = 1 << 22`
/// in `core/os/keyboard.h`, and each key is `SPECIAL | <ordinal>`. Writing
/// them that way keeps this table checkable against the header.
const key_special: i32 = 1 << 22;

const named_keys = [_]struct { names: []const []const u8, code: i32, unicode: i32 = 0 }{
    .{ .names = &.{"space"}, .code = 32, .unicode = 32 },
    .{ .names = &.{"escape"}, .code = key_special | 0x01 },
    .{ .names = &.{"tab"}, .code = key_special | 0x02 },
    .{ .names = &.{"backtab"}, .code = key_special | 0x03 },
    .{ .names = &.{"backspace"}, .code = key_special | 0x04 },
    .{ .names = &.{ "enter", "return" }, .code = key_special | 0x05 },
    .{ .names = &.{"kp_enter"}, .code = key_special | 0x06 },
    .{ .names = &.{"insert"}, .code = key_special | 0x07 },
    .{ .names = &.{"delete"}, .code = key_special | 0x08 },
    .{ .names = &.{"pause"}, .code = key_special | 0x09 },
    .{ .names = &.{"print"}, .code = key_special | 0x0A },
    .{ .names = &.{"home"}, .code = key_special | 0x0D },
    .{ .names = &.{"end"}, .code = key_special | 0x0E },
    .{ .names = &.{ "left", "arrowleft" }, .code = key_special | 0x0F },
    .{ .names = &.{ "up", "arrowup" }, .code = key_special | 0x10 },
    .{ .names = &.{ "right", "arrowright" }, .code = key_special | 0x11 },
    .{ .names = &.{ "down", "arrowdown" }, .code = key_special | 0x12 },
    .{ .names = &.{ "pageup", "page_up" }, .code = key_special | 0x13 },
    .{ .names = &.{ "pagedown", "page_down" }, .code = key_special | 0x14 },
    .{ .names = &.{"shift"}, .code = key_special | 0x15 },
    .{ .names = &.{ "ctrl", "control" }, .code = key_special | 0x16 },
    .{ .names = &.{ "meta", "cmd", "command" }, .code = key_special | 0x17 },
    .{ .names = &.{"alt"}, .code = key_special | 0x18 },
    .{ .names = &.{"capslock"}, .code = key_special | 0x19 },
    .{ .names = &.{"numlock"}, .code = key_special | 0x1A },
    .{ .names = &.{"scrolllock"}, .code = key_special | 0x1B },
    .{ .names = &.{"f1"}, .code = key_special | 0x1C },
    .{ .names = &.{"f2"}, .code = key_special | 0x1D },
    .{ .names = &.{"f3"}, .code = key_special | 0x1E },
    .{ .names = &.{"f4"}, .code = key_special | 0x1F },
    .{ .names = &.{"f5"}, .code = key_special | 0x20 },
    .{ .names = &.{"f6"}, .code = key_special | 0x21 },
    .{ .names = &.{"f7"}, .code = key_special | 0x22 },
    .{ .names = &.{"f8"}, .code = key_special | 0x23 },
    .{ .names = &.{"f9"}, .code = key_special | 0x24 },
    .{ .names = &.{"f10"}, .code = key_special | 0x25 },
    .{ .names = &.{"f11"}, .code = key_special | 0x26 },
    .{ .names = &.{"f12"}, .code = key_special | 0x27 },
};

pub const key_names = "a letter or digit, space, escape, tab, backtab, backspace, enter/return, kp_enter, insert, delete, pause, print, home, end, left, up, right, down, pageup, pagedown, shift, ctrl, meta/cmd, alt, capslock, numlock, scrolllock, f1-f12; or a Godot keycode number. Names are matched without case, and KEY_<letter> is accepted";

fn resolveKey(name: []const u8, physical: bool) Error!KeyCodes {
    for (named_keys) |key| {
        for (key.names) |candidate| {
            if (!std.ascii.eqlIgnoreCase(name, candidate)) continue;
            // Godot writes a physical binding as keycode 0 plus
            // physical_keycode; both set at once is what the editor writes
            // for a *non*-physical binding of a key that has no label.
            if (physical) return .{ .keycode = 0, .physical_keycode = key.code, .unicode = key.unicode };
            return .{ .keycode = key.code, .physical_keycode = 0, .unicode = key.unicode };
        }
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
    error_details.record(.{ .field = "keycode", .value = name, .hint = "unknown key; " ++ key_names });
    return error.UnknownKey;
}

/// `MouseButton` in `core/input/input_enums.h`. The action map editor offers
/// mouse bindings alongside keys and joypads, so an intent has to reach them.
const mouse_buttons = [_]struct { names: []const []const u8, index: i32 }{
    .{ .names = &.{"left"}, .index = 1 },
    .{ .names = &.{"right"}, .index = 2 },
    .{ .names = &.{"middle"}, .index = 3 },
    .{ .names = &.{"wheel_up"}, .index = 4 },
    .{ .names = &.{"wheel_down"}, .index = 5 },
    .{ .names = &.{"wheel_left"}, .index = 6 },
    .{ .names = &.{"wheel_right"}, .index = 7 },
    .{ .names = &.{ "xbutton1", "x1" }, .index = 8 },
    .{ .names = &.{ "xbutton2", "x2" }, .index = 9 },
};

pub const mouse_button_names = "left, right, middle, wheel_up, wheel_down, wheel_left, wheel_right, xbutton1/x1, xbutton2/x2; or the MouseButton number. Names are matched without case";

fn resolveMouseButton(name: []const u8) Error!i32 {
    for (mouse_buttons) |button| {
        for (button.names) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return button.index;
        }
    }
    error_details.record(.{ .field = "button", .value = name, .hint = "unknown mouse button; " ++ mouse_button_names });
    return error.UnknownMouseButton;
}

/// Every `JoyButton` Godot has, with the names its editor and its docs use.
/// `core/input/input_enums.h` is the source; south/east/west/north are the
/// layout-neutral aliases for the face buttons.
const joypad_buttons = [_]struct { names: []const []const u8, index: i32 }{
    .{ .names = &.{ "a", "south" }, .index = 0 },
    .{ .names = &.{ "b", "east" }, .index = 1 },
    .{ .names = &.{ "x", "west" }, .index = 2 },
    .{ .names = &.{ "y", "north" }, .index = 3 },
    .{ .names = &.{ "back", "select" }, .index = 4 },
    .{ .names = &.{ "guide", "home" }, .index = 5 },
    .{ .names = &.{"start"}, .index = 6 },
    .{ .names = &.{ "left_stick", "l3", "ls" }, .index = 7 },
    .{ .names = &.{ "right_stick", "r3", "rs" }, .index = 8 },
    .{ .names = &.{ "left_shoulder", "lb", "l1" }, .index = 9 },
    .{ .names = &.{ "right_shoulder", "rb", "r1" }, .index = 10 },
    .{ .names = &.{"dpad_up"}, .index = 11 },
    .{ .names = &.{"dpad_down"}, .index = 12 },
    .{ .names = &.{"dpad_left"}, .index = 13 },
    .{ .names = &.{"dpad_right"}, .index = 14 },
    .{ .names = &.{"misc1"}, .index = 15 },
    .{ .names = &.{"paddle1"}, .index = 16 },
    .{ .names = &.{"paddle2"}, .index = 17 },
    .{ .names = &.{"paddle3"}, .index = 18 },
    .{ .names = &.{"paddle4"}, .index = 19 },
    .{ .names = &.{"touchpad"}, .index = 20 },
    .{ .names = &.{"misc2"}, .index = 21 },
    .{ .names = &.{"misc3"}, .index = 22 },
    .{ .names = &.{"misc4"}, .index = 23 },
    .{ .names = &.{"misc5"}, .index = 24 },
    .{ .names = &.{"misc6"}, .index = 25 },
};

pub const joypad_button_names = "a/south, b/east, x/west, y/north, back/select, guide/home, start, left_stick/l3, right_stick/r3, left_shoulder/lb, right_shoulder/rb, dpad_up, dpad_down, dpad_left, dpad_right, misc1, paddle1-4, touchpad, misc2-6; or the JoyButton number. Names are matched without case";

const joypad_axes = [_]struct { names: []const []const u8, index: i32 }{
    .{ .names = &.{ "left_x", "LX" }, .index = 0 },
    .{ .names = &.{ "left_y", "LY" }, .index = 1 },
    .{ .names = &.{ "right_x", "RX" }, .index = 2 },
    .{ .names = &.{ "right_y", "RY" }, .index = 3 },
    .{ .names = &.{ "trigger_left", "LT", "l2" }, .index = 4 },
    .{ .names = &.{ "trigger_right", "RT", "r2" }, .index = 5 },
};

pub const joypad_axis_names = "left_x/LX, left_y/LY, right_x/RX, right_y/RY, trigger_left/LT, trigger_right/RT; or the JoyAxis number. Names are matched without case";

fn resolveJoypadButton(name: []const u8) Error!i32 {
    for (joypad_buttons) |button| {
        for (button.names) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return button.index;
        }
    }
    error_details.record(.{ .field = "button", .value = name, .hint = "unknown joypad button; " ++ joypad_button_names });
    return error.UnknownJoypadButton;
}

fn resolveJoypadAxis(name: []const u8) Error!i32 {
    for (joypad_axes) |axis| {
        for (axis.names) |candidate| {
            if (std.ascii.eqlIgnoreCase(name, candidate)) return axis.index;
        }
    }
    error_details.record(.{ .field = "axis", .value = name, .hint = "unknown joypad axis; " ++ joypad_axis_names });
    return error.UnknownJoypadAxis;
}

/// `"device": 0` pins a binding to one joypad; the default -1 is Godot's
/// "All Devices", which is what the editor writes unless you choose otherwise.
fn readDevice(event: std.json.ObjectMap) i64 {
    const value = event.get("device") orelse return -1;
    return switch (value) {
        .integer => |n| n,
        else => -1,
    };
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

test "named keys cover Godot's special keys, with modifiers and a raw keycode" {
    const allocator = std.testing.allocator;
    // Values are SPECIAL | ordinal from core/os/keyboard.h: Escape is
    // 0x400001, Enter 0x400005, F12 0x400027.
    const cases = [_]struct { intent: []const u8, expect: []const u8 }{
        .{ .intent = "{ \"type\": \"key\", \"keycode\": \"Escape\" }", .expect = "\"physical_keycode\":4194305" },
        .{ .intent = "{ \"type\": \"key\", \"keycode\": \"enter\" }", .expect = "\"physical_keycode\":4194309" },
        .{ .intent = "{ \"type\": \"key\", \"keycode\": \"F12\" }", .expect = "\"physical_keycode\":4194343" },
        .{ .intent = "{ \"type\": \"key\", \"keycode\": \"TAB\", \"physical\": false }", .expect = "\"keycode\":4194306" },
        // The escape hatch: any keycode the table does not name.
        .{ .intent = "{ \"type\": \"key\", \"keycode\": 4194306 }", .expect = "\"physical_keycode\":4194306" },
        .{ .intent = "{ \"type\": \"key\", \"keycode\": \"S\", \"physical\": false, \"ctrl\": true }", .expect = "\"ctrl_pressed\":true" },
        .{ .intent = "{ \"type\": \"key\", \"keycode\": \"Tab\", \"shift\": true }", .expect = "\"shift_pressed\":true" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.intent, .{});
        defer parsed.deinit();
        const text = try formatEventFromJson(allocator, parsed.value.object);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, case.expect) == null) {
            std.debug.print("{s}\n  expected {s}\n", .{ text, case.expect });
            return error.TestExpectedEqual;
        }
    }
}

test "joypad names cover every JoyButton and JoyAxis" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { intent: []const u8, expect: []const u8 }{
        .{ .intent = "{ \"type\": \"joypad_button\", \"button\": \"left_stick\" }", .expect = "\"button_index\":7" },
        .{ .intent = "{ \"type\": \"joypad_button\", \"button\": \"L3\" }", .expect = "\"button_index\":7" },
        .{ .intent = "{ \"type\": \"joypad_button\", \"button\": \"rb\" }", .expect = "\"button_index\":10" },
        .{ .intent = "{ \"type\": \"joypad_button\", \"button\": \"start\" }", .expect = "\"button_index\":6" },
        .{ .intent = "{ \"type\": \"joypad_button\", \"button\": 19 }", .expect = "\"button_index\":19" },
        .{ .intent = "{ \"type\": \"joypad_motion\", \"axis\": \"trigger_left\", \"axis_value\": 1.0 }", .expect = "\"axis\":4" },
        .{ .intent = "{ \"type\": \"joypad_motion\", \"axis\": \"RT\", \"axis_value\": 1.0 }", .expect = "\"axis\":5" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.intent, .{});
        defer parsed.deinit();
        const text = try formatEventFromJson(allocator, parsed.value.object);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, case.expect) == null) {
            std.debug.print("{s}\n  expected {s}\n", .{ text, case.expect });
            return error.TestExpectedEqual;
        }
    }

    // Every index in Godot's enum is reachable by name, 0 to 25 and 0 to 5.
    var seen_buttons = [_]bool{false} ** 26;
    for (joypad_buttons) |button| seen_buttons[@intCast(button.index)] = true;
    for (seen_buttons) |ok| try std.testing.expect(ok);
    var seen_axes = [_]bool{false} ** 6;
    for (joypad_axes) |axis| seen_axes[@intCast(axis.index)] = true;
    for (seen_axes) |ok| try std.testing.expect(ok);
}

test "a whole axis_value keeps the .0 Godot writes" {
    const allocator = std.testing.allocator;
    // Godot's VariantWriter appends .0 to a whole float, so -1 here would be
    // rewritten by the editor on the next save.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, "{ \"type\": \"joypad_motion\", \"axis\": \"left_y\", \"axis_value\": -1.0 }", .{});
    defer parsed.deinit();
    const text = try formatEventFromJson(allocator, parsed.value.object);
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"axis_value\":-1.0") != null);
}

test "mouse buttons are bindable, with the property shape Godot writes" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { intent: []const u8, expect: []const u8 }{
        .{ .intent = "{ \"type\": \"mouse_button\", \"button\": \"left\" }", .expect = "\"button_index\":1" },
        .{ .intent = "{ \"type\": \"mouse_button\", \"button\": \"RIGHT\" }", .expect = "\"button_index\":2" },
        .{ .intent = "{ \"type\": \"mouse_button\", \"button\": \"wheel_up\" }", .expect = "\"button_index\":4" },
        .{ .intent = "{ \"type\": \"mouse_button\", \"button\": 3 }", .expect = "\"button_index\":3" },
        .{ .intent = "{ \"type\": \"mouse_button\", \"button\": \"x1\", \"shift\": true }", .expect = "\"shift_pressed\":true" },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, case.intent, .{});
        defer parsed.deinit();
        const text = try formatEventFromJson(allocator, parsed.value.object);
        defer allocator.free(text);
        if (std.mem.indexOf(u8, text, case.expect) == null) {
            std.debug.print("{s}\n  expected {s}\n", .{ text, case.expect });
            return error.TestExpectedEqual;
        }
        // Godot's var_to_str of an InputEventMouseButton, property for
        // property; a missing one makes the editor rewrite the line.
        try std.testing.expect(std.mem.indexOf(u8, text, "\"button_mask\":0,\"position\":Vector2(0, 0),\"global_position\":Vector2(0, 0),\"factor\":1.0") != null);
        try std.testing.expect(std.mem.indexOf(u8, text, "\"canceled\":false,\"pressed\":false,\"double_click\":false,\"script\":null)") != null);
    }

    // Every MouseButton in the enum is reachable by name, 1 to 9.
    var seen = [_]bool{false} ** 10;
    for (mouse_buttons) |button| seen[@intCast(button.index)] = true;
    for (seen[1..]) |ok| try std.testing.expect(ok);
}
