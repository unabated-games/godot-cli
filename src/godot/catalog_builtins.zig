//! Document-only Godot builtin catalog entries shipped inside godot-cli.

const std = @import("std");

const embedded_json = @embedFile("../catalog/builtins.json");

pub const SignalDoc = struct {
    name: []const u8,
    doc: []const u8,
};

pub const BuiltinEntry = struct {
    id: []const u8,
    class_name: []const u8,
    inherits: []const u8 = "",
    tags: []const []const u8 = &.{},
    summary: []const u8 = "",
    when_to_use: []const u8 = "",
    when_not_to_use: []const u8 = "",
    related_ids: []const []const u8 = &.{},
    signals: []SignalDoc = &.{},
    source: []const u8 = "builtin",
};

pub const LoadError = error{
    OutOfMemory,
    InvalidBuiltinCatalog,
};

pub fn allEntries(allocator: std.mem.Allocator) LoadError![]BuiltinEntry {
    return try parseEmbedded(allocator);
}

pub fn findById(allocator: std.mem.Allocator, id: []const u8) LoadError!?BuiltinEntry {
    const entries = try allEntries(allocator);
    defer freeEntries(allocator, entries);
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.id, id)) {
            return try cloneEntry(allocator, entry);
        }
    }
    return null;
}

pub fn isBuiltinId(id: []const u8) bool {
    return std.mem.startsWith(u8, id, "godot/");
}

pub fn freeEntries(allocator: std.mem.Allocator, entries: []BuiltinEntry) void {
    for (entries) |entry| freeEntry(allocator, entry);
    allocator.free(entries);
}

pub fn freeEntry(allocator: std.mem.Allocator, entry: BuiltinEntry) void {
    allocator.free(entry.id);
    allocator.free(entry.class_name);
    allocator.free(entry.inherits);
    for (entry.tags) |tag| allocator.free(tag);
    allocator.free(entry.tags);
    allocator.free(entry.summary);
    allocator.free(entry.when_to_use);
    allocator.free(entry.when_not_to_use);
    for (entry.related_ids) |item| allocator.free(item);
    allocator.free(entry.related_ids);
    for (entry.signals) |signal_doc| {
        allocator.free(signal_doc.name);
        allocator.free(signal_doc.doc);
    }
    allocator.free(entry.signals);
}

fn parseEmbedded(allocator: std.mem.Allocator) LoadError![]BuiltinEntry {
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        embedded_json,
        .{},
    ) catch return error.InvalidBuiltinCatalog;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .array) return error.InvalidBuiltinCatalog;

    var entries: std.ArrayList(BuiltinEntry) = .empty;
    errdefer {
        for (entries.items) |entry| freeEntry(allocator, entry);
        entries.deinit(allocator);
    }

    for (root.array.items) |item| {
        if (item != .object) return error.InvalidBuiltinCatalog;
        try entries.append(allocator, try parseEntryObject(allocator, item.object));
    }

    return try entries.toOwnedSlice(allocator);
}

fn parseEntryObject(allocator: std.mem.Allocator, obj: std.json.ObjectMap) LoadError!BuiltinEntry {
    const id = try requiredString(allocator, obj, "id");
    errdefer allocator.free(id);
    const class_name = try optionalString(allocator, obj, "class_name");
    errdefer allocator.free(class_name);

    const tags = try readStringArray(allocator, obj.get("tags"));
    errdefer freeStringSlice(allocator, tags);
    const related_ids = try readStringArray(allocator, obj.get("related_ids"));
    errdefer freeStringSlice(allocator, related_ids);
    const signals = try readSignalDocs(allocator, obj.get("signals"));
    errdefer freeSignalDocs(allocator, signals);

    return .{
        .id = id,
        .class_name = class_name,
        .inherits = try optionalString(allocator, obj, "inherits"),
        .tags = tags,
        .summary = try optionalString(allocator, obj, "summary"),
        .when_to_use = try optionalString(allocator, obj, "when_to_use"),
        .when_not_to_use = try optionalString(allocator, obj, "when_not_to_use"),
        .related_ids = related_ids,
        .signals = signals,
    };
}

fn cloneEntry(allocator: std.mem.Allocator, entry: BuiltinEntry) LoadError!BuiltinEntry {
    const tags = try dupStringSlice(allocator, entry.tags);
    errdefer freeStringSlice(allocator, tags);
    const related_ids = try dupStringSlice(allocator, entry.related_ids);
    errdefer freeStringSlice(allocator, related_ids);

    var signals: std.ArrayList(SignalDoc) = .empty;
    errdefer {
        for (signals.items) |signal_doc| {
            allocator.free(signal_doc.name);
            allocator.free(signal_doc.doc);
        }
        signals.deinit(allocator);
    }
    for (entry.signals) |signal_doc| {
        try signals.append(allocator, .{
            .name = try allocator.dupe(u8, signal_doc.name),
            .doc = try allocator.dupe(u8, signal_doc.doc),
        });
    }

    return .{
        .id = try allocator.dupe(u8, entry.id),
        .class_name = try allocator.dupe(u8, entry.class_name),
        .inherits = try allocator.dupe(u8, entry.inherits),
        .tags = tags,
        .summary = try allocator.dupe(u8, entry.summary),
        .when_to_use = try allocator.dupe(u8, entry.when_to_use),
        .when_not_to_use = try allocator.dupe(u8, entry.when_not_to_use),
        .related_ids = related_ids,
        .signals = try signals.toOwnedSlice(allocator),
    };
}

fn requiredString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) LoadError![]const u8 {
    const value = obj.get(key) orelse return error.InvalidBuiltinCatalog;
    if (value != .string) return error.InvalidBuiltinCatalog;
    return try allocator.dupe(u8, value.string);
}

fn optionalString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, key: []const u8) LoadError![]const u8 {
    const value = obj.get(key) orelse return try allocator.dupe(u8, "");
    if (value != .string) return error.InvalidBuiltinCatalog;
    return try allocator.dupe(u8, value.string);
}

fn readStringArray(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]const []const u8 {
    const array_value = value orelse return &.{};
    if (array_value != .array) return error.InvalidBuiltinCatalog;
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }
    for (array_value.array.items) |item| {
        if (item != .string) return error.InvalidBuiltinCatalog;
        try items.append(allocator, try allocator.dupe(u8, item.string));
    }
    return try items.toOwnedSlice(allocator);
}

fn readSignalDocs(allocator: std.mem.Allocator, value: ?std.json.Value) LoadError![]SignalDoc {
    const array_value = value orelse return &.{};
    if (array_value != .array) return error.InvalidBuiltinCatalog;
    var items: std.ArrayList(SignalDoc) = .empty;
    errdefer {
        for (items.items) |item| {
            allocator.free(item.name);
            allocator.free(item.doc);
        }
        items.deinit(allocator);
    }
    for (array_value.array.items) |item| {
        if (item != .object) return error.InvalidBuiltinCatalog;
        const name = try requiredString(allocator, item.object, "name");
        errdefer allocator.free(name);
        const doc = try optionalString(allocator, item.object, "doc");
        errdefer allocator.free(doc);
        try items.append(allocator, .{ .name = name, .doc = doc });
    }
    return try items.toOwnedSlice(allocator);
}

fn dupStringSlice(allocator: std.mem.Allocator, items: []const []const u8) LoadError![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeStringSlice(allocator, out.items);
    for (items) |item| {
        try out.append(allocator, try allocator.dupe(u8, item));
    }
    return try out.toOwnedSlice(allocator);
}

fn freeStringSlice(allocator: std.mem.Allocator, items: []const []const u8) void {
    for (items) |item| allocator.free(item);
    allocator.free(items);
}

fn freeSignalDocs(allocator: std.mem.Allocator, items: []const SignalDoc) void {
    for (items) |item| {
        allocator.free(item.name);
        allocator.free(item.doc);
    }
    allocator.free(items);
}

test "load builtin button entry" {
    const allocator = std.testing.allocator;
    const entry = try findById(allocator, "godot/ui/Button");
    defer freeEntry(allocator, entry.?);
    try std.testing.expectEqualStrings("Button", entry.?.class_name);
    try std.testing.expect(entry.?.signals.len >= 1);
}
