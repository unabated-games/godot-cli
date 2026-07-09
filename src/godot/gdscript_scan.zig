//! Heuristic GDScript parser for @export annotations and signal declarations.

const std = @import("std");

pub const ExportInfo = struct {
    name: []const u8,
    type_hint: []const u8 = "",
    default_value: []const u8 = "",
    group: []const u8 = "",
    annotations: []const []const u8 = &.{},

    pub fn deinit(self: *const ExportInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.type_hint);
        allocator.free(self.default_value);
        allocator.free(self.group);
        for (self.annotations) |annotation| allocator.free(annotation);
        allocator.free(self.annotations);
    }
};

pub const SignalInfo = struct {
    name: []const u8,
    args: []const u8 = "",

    pub fn deinit(self: *const SignalInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.args);
    }
};

pub const ScriptInterface = struct {
    exports: []ExportInfo = &.{},
    signals: []SignalInfo = &.{},
    parse_complete: bool = true,

    pub fn deinit(self: *ScriptInterface, allocator: std.mem.Allocator) void {
        for (self.exports) |*item| item.deinit(allocator);
        allocator.free(self.exports);
        for (self.signals) |*item| item.deinit(allocator);
        allocator.free(self.signals);
    }
};

pub const ParseError = error{
    OutOfMemory,
};

pub fn parseScript(allocator: std.mem.Allocator, source: []const u8) ParseError!ScriptInterface {
    var exports: std.ArrayList(ExportInfo) = .empty;
    errdefer {
        for (exports.items) |*item| item.deinit(allocator);
        exports.deinit(allocator);
    }
    var signals: std.ArrayList(SignalInfo) = .empty;
    errdefer {
        for (signals.items) |*item| item.deinit(allocator);
        signals.deinit(allocator);
    }

    var current_group: []const u8 = "";
    errdefer if (current_group.len > 0) allocator.free(current_group);

    var pending_annotations: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (pending_annotations.items) |annotation| allocator.free(annotation);
        pending_annotations.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0 or trimmed[0] == '#') continue;

        if (std.mem.startsWith(u8, trimmed, "@export_group")) {
            allocator.free(current_group);
            current_group = try parseGroupName(allocator, trimmed, "@export_group");
            clearAnnotations(allocator, &pending_annotations);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "@export_subgroup")) {
            allocator.free(current_group);
            current_group = try parseGroupName(allocator, trimmed, "@export_subgroup");
            clearAnnotations(allocator, &pending_annotations);
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "@export_category")) {
            allocator.free(current_group);
            current_group = try parseGroupName(allocator, trimmed, "@export_category");
            clearAnnotations(allocator, &pending_annotations);
            continue;
        }

        if (std.mem.startsWith(u8, trimmed, "signal ")) {
            clearAnnotations(allocator, &pending_annotations);
            if (try parseSignalLine(allocator, trimmed)) |signal_info| {
                try signals.append(allocator, signal_info);
            }
            continue;
        }

        if (isStandaloneAnnotationLine(trimmed)) {
            try pending_annotations.append(allocator, try allocator.dupe(u8, trimmed));
            continue;
        }

        if (findVarConstDeclStart(trimmed)) |decl_start| {
            const prefix = std.mem.trim(u8, trimmed[0..decl_start], &std.ascii.whitespace);
            if (prefix.len > 0 and prefix[0] == '@') {
                try pending_annotations.append(allocator, try allocator.dupe(u8, prefix));
            }

            const decl_line = std.mem.trim(u8, trimmed[decl_start..], &std.ascii.whitespace);
            if (hasExportAnnotation(&pending_annotations)) {
                if (try parseExportDeclaration(allocator, decl_line, current_group, &pending_annotations)) |export_info| {
                    try exports.append(allocator, export_info);
                }
            }
            clearAnnotations(allocator, &pending_annotations);
            continue;
        }

        clearAnnotations(allocator, &pending_annotations);
    }

    allocator.free(current_group);
    clearAnnotations(allocator, &pending_annotations);
    pending_annotations.deinit(allocator);

    return .{
        .exports = try exports.toOwnedSlice(allocator),
        .signals = try signals.toOwnedSlice(allocator),
        .parse_complete = true,
    };
}

fn isStandaloneAnnotationLine(line: []const u8) bool {
    if (!std.mem.startsWith(u8, line, "@")) return false;
    return findVarConstDeclStart(line) == null;
}

fn findVarConstDeclStart(line: []const u8) ?usize {
    inline for (.{ " var ", " const ", "var ", "const " }) |pattern| {
        if (std.mem.indexOf(u8, line, pattern)) |idx| {
            return if (pattern[0] == ' ') idx + 1 else idx;
        }
    }
    return null;
}

fn hasExportAnnotation(annotations: *const std.ArrayList([]const u8)) bool {
    for (annotations.items) |annotation| {
        if (std.mem.startsWith(u8, annotation, "@export")) return true;
    }
    return false;
}

fn clearAnnotations(allocator: std.mem.Allocator, annotations: *std.ArrayList([]const u8)) void {
    for (annotations.items) |annotation| allocator.free(annotation);
    annotations.clearRetainingCapacity();
}

fn parseGroupName(allocator: std.mem.Allocator, line: []const u8, prefix: []const u8) ParseError![]const u8 {
    const rest = std.mem.trim(u8, line[prefix.len..], &std.ascii.whitespace);
    if (rest.len == 0) return try allocator.dupe(u8, "");
    if (rest[0] == '(') {
        const close = std.mem.lastIndexOfScalar(u8, rest, ')') orelse return try allocator.dupe(u8, "");
        const inner = std.mem.trim(u8, rest[1..close], &std.ascii.whitespace);
        return parseQuotedOrBare(allocator, inner);
    }
    return parseQuotedOrBare(allocator, rest);
}

fn parseQuotedOrBare(allocator: std.mem.Allocator, text: []const u8) ParseError![]const u8 {
    if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') {
        return try allocator.dupe(u8, text[1 .. text.len - 1]);
    }
    return try allocator.dupe(u8, text);
}

fn parseSignalLine(allocator: std.mem.Allocator, line: []const u8) ParseError!?SignalInfo {
    const rest = std.mem.trim(u8, line["signal".len..], &std.ascii.whitespace);
    if (rest.len == 0) return null;
    const name_end = std.mem.indexOfAny(u8, rest, "(:") orelse rest.len;
    const name = std.mem.trim(u8, rest[0..name_end], &std.ascii.whitespace);
    if (name.len == 0) return null;

    var args: []const u8 = "";
    if (std.mem.indexOfScalar(u8, rest, '(')) |open| {
        const close = std.mem.lastIndexOfScalar(u8, rest, ')') orelse rest.len - 1;
        args = std.mem.trim(u8, rest[open + 1 .. close], &std.ascii.whitespace);
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .args = try allocator.dupe(u8, args),
    };
}

fn parseExportDeclaration(
    allocator: std.mem.Allocator,
    line: []const u8,
    group: []const u8,
    annotations: *const std.ArrayList([]const u8),
) ParseError!?ExportInfo {
    if (!std.mem.startsWith(u8, line, "var ") and !std.mem.startsWith(u8, line, "const ")) return null;

    const decl = std.mem.trim(u8, if (std.mem.startsWith(u8, line, "var ")) line[4..] else line[6..], &std.ascii.whitespace);
    if (decl.len == 0) return null;

    const name_end = std.mem.indexOfAny(u8, decl, " :=") orelse return null;
    const name = std.mem.trim(u8, decl[0..name_end], &std.ascii.whitespace);
    if (name.len == 0) return null;

    var type_hint: []const u8 = "";
    var default_value: []const u8 = "";
    const tail = std.mem.trim(u8, decl[name_end..], &std.ascii.whitespace);
    if (tail.len > 0 and tail[0] == ':') {
        const after_colon = std.mem.trim(u8, tail[1..], &std.ascii.whitespace);
        const default_idx = std.mem.indexOf(u8, after_colon, " = ") orelse std.mem.indexOfScalar(u8, after_colon, '=');
        if (default_idx) |idx| {
            type_hint = std.mem.trim(u8, after_colon[0..idx], &std.ascii.whitespace);
            const default_start = if (after_colon[idx] == ' ') idx + 3 else idx + 1;
            default_value = std.mem.trim(u8, after_colon[default_start..], &std.ascii.whitespace);
        } else {
            type_hint = after_colon;
        }
    } else if (std.mem.indexOf(u8, decl, " = ")) |eq| {
        default_value = std.mem.trim(u8, decl[eq + 3 ..], &std.ascii.whitespace);
    } else if (std.mem.indexOfScalar(u8, decl, '=')) |eq| {
        default_value = std.mem.trim(u8, decl[eq + 1 ..], &std.ascii.whitespace);
    }

    if (std.mem.indexOfScalar(u8, default_value, ':')) |setter| {
        default_value = std.mem.trim(u8, default_value[0..setter], &std.ascii.whitespace);
    }

    var copied_annotations: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (copied_annotations.items) |annotation| allocator.free(annotation);
        copied_annotations.deinit(allocator);
    }
    for (annotations.items) |annotation| {
        try copied_annotations.append(allocator, try allocator.dupe(u8, annotation));
    }

    return .{
        .name = try allocator.dupe(u8, name),
        .type_hint = try allocator.dupe(u8, type_hint),
        .default_value = try allocator.dupe(u8, default_value),
        .group = try allocator.dupe(u8, group),
        .annotations = try copied_annotations.toOwnedSlice(allocator),
    };
}

test "parse button script exports and signals" {
    const allocator = std.testing.allocator;
    const source =
        \\@tool
        \\extends MarginContainer
        \\
        \\signal button_pressed
        \\
        \\@export var label_text : String = "Label Text"
        \\
    ;
    var parsed = try parseScript(allocator, source);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), parsed.exports.len);
    try std.testing.expectEqualStrings("label_text", parsed.exports[0].name);
    try std.testing.expectEqualStrings("String", parsed.exports[0].type_hint);
    try std.testing.expectEqual(@as(usize, 1), parsed.signals.len);
    try std.testing.expectEqualStrings("button_pressed", parsed.signals[0].name);
}

test "parse export annotations and groups" {
    const allocator = std.testing.allocator;
    const source =
        \\@export_group("Movement")
        \\@export_range(0, 100, 0.1) var speed: float = 10.0
        \\@export_file("*.tscn") var scene_path: String
        \\
    ;
    var parsed = try parseScript(allocator, source);
    defer parsed.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), parsed.exports.len);
    try std.testing.expectEqualStrings("speed", parsed.exports[0].name);
    try std.testing.expectEqualStrings("Movement", parsed.exports[0].group);
    try std.testing.expectEqualStrings("scene_path", parsed.exports[1].name);
}
