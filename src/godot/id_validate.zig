//! Validation helpers for Godot resource UIDs and scene-local IDs.
//! Foundation for a future `validate` / detection command (LLM or manual edit checks).

const std = @import("std");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");
const document = @import("text_format/document.zig");

pub const Severity = enum {
    err,
    warning,
};

pub const Issue = struct {
    severity: Severity,
    kind: []const u8,
    message: []const u8,
    line: ?usize = null,
};

pub const Report = struct {
    issues: std.ArrayList(Issue),

    pub fn init(allocator: std.mem.Allocator) Report {
        _ = allocator;
        return .{ .issues = .empty };
    }

    pub fn deinit(self: *Report, allocator: std.mem.Allocator) void {
        for (self.issues.items) |issue| {
            allocator.free(issue.kind);
            allocator.free(issue.message);
        }
        self.issues.deinit(allocator);
    }

    pub fn add(
        self: *Report,
        allocator: std.mem.Allocator,
        severity: Severity,
        kind: []const u8,
        message: []const u8,
        line: ?usize,
    ) !void {
        try self.issues.append(allocator, .{
            .severity = severity,
            .kind = try allocator.dupe(u8, kind),
            .message = try allocator.dupe(u8, message),
            .line = line,
        });
    }
};

/// Godot `generate_scene_unique_id` suffix alphabet: a-y and 0-9.
pub fn isSceneIdSuffixChar(c: u8) bool {
    return (c >= 'a' and c <= 'y') or (c >= '0' and c <= '9');
}

pub fn isAsciiIdentifierChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// Validate `uid://` text encoding.
pub fn validateUidText(text: []const u8) ?Issue {
    if (resource_uid.textToId(text) == resource_uid.invalid_id) {
        return .{
            .severity = .err,
            .kind = "invalid_uid_text",
            .message = "uid text is not a valid Godot Resource UID",
            .line = null,
        };
    }
    return null;
}

/// Validate scene-local resource id (`ext_resource` / `sub_resource` id= attribute).
pub fn validateSceneResourceId(id: []const u8) ?Issue {
    if (id.len == 0) {
        return .{
            .severity = .err,
            .kind = "empty_scene_id",
            .message = "scene resource id is empty",
            .line = null,
        };
    }

    for (id) |c| {
        if (!isAsciiIdentifierChar(c)) {
            return .{
                .severity = .err,
                .kind = "invalid_scene_id_char",
                .message = "scene resource id contains invalid characters",
                .line = null,
            };
        }
    }

    const underscore = std.mem.lastIndexOfScalar(u8, id, '_');
    if (underscore) |at| {
        const suffix = id[at + 1 ..];
        if (suffix.len == 5) {
            for (suffix) |c| {
                if (!isSceneIdSuffixChar(c)) {
                    return .{
                        .severity = .warning,
                        .kind = "unexpected_scene_id_suffix",
                        .message = "scene id suffix is not from Godot's generate_scene_unique_id alphabet",
                        .line = null,
                    };
                }
            }
            return null;
        }
    }

    // Legacy numeric-only ids still load in Godot.
    for (id) |c| {
        if (c < '0' or c > '9') {
            return .{
                .severity = .warning,
                .kind = "nonstandard_scene_id",
                .message = "scene resource id does not match editor format (expected N_suffix or Class_suffix)",
                .line = null,
            };
        }
    }
    return null;
}

pub fn validateDocument(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    cache: ?*const uid_cache.Cache,
) !Report {
    var report = Report.init(allocator);
    errdefer report.deinit(allocator);

    var seen_ids = std.StringHashMap(void).init(allocator);
    defer seen_ids.deinit();

    for (doc.sections.items) |section| {
        const name = section.header.name;

        if (std.mem.eql(u8, name, "gd_scene") or std.mem.eql(u8, name, "gd_resource")) {
            if (section.header.getString("uid")) |uid_text| {
                if (validateUidText(uid_text)) |issue| {
                    try report.add(allocator, issue.severity, issue.kind, issue.message, section.line);
                } else if (cache) |c| {
                    const id = resource_uid.textToId(uid_text);
                    if (!c.hasId(id)) {
                        try report.add(
                            allocator,
                            .warning,
                            "uid_not_in_cache",
                            "scene/resource uid is not present in uid_cache.bin",
                            section.line,
                        );
                    }
                }
            }
        }

        if (std.mem.eql(u8, name, "ext_resource") or std.mem.eql(u8, name, "sub_resource")) {
            const id = section.header.getString("id") orelse {
                try report.add(allocator, .err, "missing_scene_id", "resource section is missing id=", section.line);
                continue;
            };

            if (validateSceneResourceId(id)) |issue| {
                try report.add(allocator, issue.severity, issue.kind, issue.message, section.line);
            }

            const gop = try seen_ids.getOrPut(id);
            if (gop.found_existing) {
                try report.add(allocator, .err, "duplicate_scene_id", "duplicate scene resource id in file", section.line);
            }

            if (section.header.getString("uid")) |uid_text| {
                if (validateUidText(uid_text)) |issue| {
                    try report.add(allocator, issue.severity, issue.kind, issue.message, section.line);
                } else if (cache) |c| {
                    const uid = resource_uid.textToId(uid_text);
                    if (!c.hasId(uid)) {
                        try report.add(
                            allocator,
                            .warning,
                            "uid_not_in_cache",
                            "ext_resource uid is not present in uid_cache.bin",
                            section.line,
                        );
                    } else if (section.header.getString("path")) |path| {
                        const cached_path = c.pathForId(uid).?;
                        if (!std.mem.eql(u8, cached_path, path)) {
                            try report.add(
                                allocator,
                                .err,
                                "uid_path_mismatch",
                                "ext_resource uid does not match uid_cache path for the declared path",
                                section.line,
                            );
                        }
                    }
                }
            }
        }
    }

    return report;
}

test "detect duplicate scene ids" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[ext_resource type="Script" path="res://a.gd" id="1_abcde"]
        \\[ext_resource type="Script" path="res://b.gd" id="1_abcde"]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var report = try validateDocument(allocator, &doc, null);
    defer report.deinit(allocator);

    try std.testing.expect(report.issues.items.len >= 1);
}
