//! Validation helpers for Godot resource UIDs and scene-local IDs.
//! Foundation for a future `validate` / detection command (LLM or manual edit checks).

const std = @import("std");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");
const project_config = @import("project_config.zig");
const document = @import("text_format/document.zig");
const node_section_order = @import("node_section_order.zig");
const scene_connections = @import("scene_connections.zig");

pub const ValidateContext = struct {
    cache: ?*const uid_cache.Cache = null,
    project_name: ?[]const u8 = null,
    project_root: ?[]const u8 = null,
    /// Bytes of the file being validated (for stale uid checks on gd_scene/gd_resource).
    file_bytes: ?[]const u8 = null,
    /// `res://` path of the file being validated.
    resource_path: ?[]const u8 = null,
    io: ?std.Io = null,
};

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

    // `Class_hint` ids come from id_hint in patches and intents, so an agent
    // can reference a resource it is about to create. Godot loads any id
    // string; only the editor's own generated ids have the 5-character suffix.
    if (underscore) |at| {
        if (at > 0 and at + 1 < id.len) return null;
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

/// Node `unique_id` must be a positive int32 (Godot skips 0).
pub fn validateNodeUniqueId(value: i64) ?Issue {
    if (value <= 0) {
        return .{
            .severity = .err,
            .kind = "invalid_node_unique_id",
            .message = "node unique_id must be a positive integer",
            .line = null,
        };
    }
    if (value > 0x7FFFFFFF) {
        return .{
            .severity = .err,
            .kind = "invalid_node_unique_id",
            .message = "node unique_id exceeds int32 range",
            .line = null,
        };
    }
    return null;
}

fn checkStaleUidForPath(
    report: *Report,
    allocator: std.mem.Allocator,
    uid_text: []const u8,
    project_name: []const u8,
    resource_path: []const u8,
    file_bytes: []const u8,
    line: usize,
) !void {
    if (validateUidText(uid_text) != null) return;

    const declared = resource_uid.textToId(uid_text);
    const expected = try resource_uid.createIdForPath(allocator, project_name, resource_path, file_bytes);
    if (declared != expected) {
        try report.add(
            allocator,
            .warning,
            "stale_uid_for_path",
            "declared uid does not match create_id_for_path for current file bytes",
            line,
        );
    }
}

fn checkExtResourceStaleUid(
    report: *Report,
    allocator: std.mem.Allocator,
    ctx: ValidateContext,
    uid_text: []const u8,
    res_path: []const u8,
    line: usize,
) !void {
    const project_name = ctx.project_name orelse return;
    const project_root = ctx.project_root orelse return;
    const io = ctx.io orelse return;
    if (validateUidText(uid_text) != null) return;

    const fs_path = try project_config.resPathToFilesystem(allocator, project_root, res_path);
    const fs_path_owned = fs_path orelse return;
    defer allocator.free(fs_path_owned);

    const ext_bytes = std.Io.Dir.cwd().readFileAlloc(io, fs_path_owned, allocator, .unlimited) catch return;
    defer allocator.free(ext_bytes);

    const declared = resource_uid.textToId(uid_text);
    const expected = try resource_uid.createIdForPath(allocator, project_name, res_path, ext_bytes);
    if (declared != expected) {
        try report.add(
            allocator,
            .warning,
            "stale_uid_for_path",
            "ext_resource uid does not match create_id_for_path for referenced file bytes",
            line,
        );
    }
}

pub fn hasErrors(report: *const Report) bool {
    for (report.issues.items) |issue| {
        if (issue.severity == .err) return true;
    }
    return false;
}

const ResourceRefKind = enum { ext, sub };

const ResourceRef = struct {
    kind: ResourceRefKind,
    id: []const u8,
};

fn collectDeclaredIds(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    ext_ids: *std.StringHashMap(void),
    sub_ids: *std.StringHashMap(void),
) !void {
    for (doc.sections.items) |section| {
        const id = section.header.getString("id") orelse continue;
        const id_copy = try allocator.dupe(u8, id);
        const target = if (std.mem.eql(u8, section.header.name, "ext_resource"))
            ext_ids
        else if (std.mem.eql(u8, section.header.name, "sub_resource"))
            sub_ids
        else
            continue;
        const gop = try target.getOrPut(id_copy);
        if (gop.found_existing) allocator.free(id_copy);
    }
}

fn scanPropertyReferences(allocator: std.mem.Allocator, raw: []const u8, refs: *std.ArrayList(ResourceRef)) !void {
    const patterns = [_]struct { prefix: []const u8, kind: ResourceRefKind }{
        .{ .prefix = "ExtResource(\"", .kind = .ext },
        .{ .prefix = "SubResource(\"", .kind = .sub },
    };

    for (patterns) |pattern| {
        var start: usize = 0;
        while (std.mem.indexOfPos(u8, raw, start, pattern.prefix)) |found| {
            const id_start = found + pattern.prefix.len;
            const id_end = std.mem.indexOfPos(u8, raw, id_start, "\"") orelse break;
            const id = try allocator.dupe(u8, raw[id_start..id_end]);
            try refs.append(allocator, .{ .kind = pattern.kind, .id = id });
            start = id_end + 1;
        }
    }
}

pub fn validateDocument(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    ctx: ValidateContext,
) !Report {
    var report = Report.init(allocator);
    errdefer report.deinit(allocator);

    var seen_ids = std.StringHashMap(void).init(allocator);
    defer seen_ids.deinit();

    var seen_node_unique_ids = std.AutoHashMap(i64, void).init(allocator);
    defer seen_node_unique_ids.deinit();

    var seen_sub_resource = false;
    for (doc.sections.items) |section| {
        const name = section.header.name;

        if (seen_sub_resource and std.mem.eql(u8, name, "ext_resource")) {
            try report.add(
                allocator,
                .err,
                "resource_section_order",
                "ext_resource must appear before sub_resource sections (Godot parse error)",
                section.line,
            );
        }
        if (std.mem.eql(u8, name, "sub_resource")) seen_sub_resource = true;

        if (std.mem.eql(u8, name, "gd_scene") or std.mem.eql(u8, name, "gd_resource")) {
            if (section.header.getString("uid")) |uid_text| {
                if (validateUidText(uid_text)) |issue| {
                    try report.add(allocator, issue.severity, issue.kind, issue.message, section.line);
                } else {
                    if (ctx.project_name) |project_name| {
                        if (ctx.file_bytes) |file_bytes| {
                            if (ctx.resource_path) |resource_path| {
                                try checkStaleUidForPath(
                                    &report,
                                    allocator,
                                    uid_text,
                                    project_name,
                                    resource_path,
                                    file_bytes,
                                    section.line,
                                );
                            }
                        }
                    }

                    if (ctx.cache) |c| {
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
        }

        if (std.mem.eql(u8, name, "node")) {
            if (section.header.getInteger("unique_id")) |unique_id| {
                if (validateNodeUniqueId(unique_id)) |issue| {
                    try report.add(allocator, issue.severity, issue.kind, issue.message, section.line);
                } else {
                    const gop = try seen_node_unique_ids.getOrPut(unique_id);
                    if (gop.found_existing) {
                        try report.add(
                            allocator,
                            .err,
                            "duplicate_node_unique_id",
                            "duplicate node unique_id in file",
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
                } else {
                    if (std.mem.eql(u8, name, "ext_resource")) {
                        if (section.header.getString("path")) |path| {
                            try checkExtResourceStaleUid(&report, allocator, ctx, uid_text, path, section.line);
                        }
                    }

                    if (ctx.cache) |c| {
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
    }

    var ext_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = ext_ids.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        ext_ids.deinit();
    }
    var sub_ids = std.StringHashMap(void).init(allocator);
    defer {
        var it = sub_ids.keyIterator();
        while (it.next()) |key| allocator.free(key.*);
        sub_ids.deinit();
    }
    try collectDeclaredIds(allocator, doc, &ext_ids, &sub_ids);

    var refs: std.ArrayList(ResourceRef) = .empty;
    defer {
        for (refs.items) |ref| allocator.free(ref.id);
        refs.deinit(allocator);
    }

    for (doc.sections.items) |section| {
        for (section.properties.items) |prop| {
            try scanPropertyReferences(allocator, prop.raw, &refs);
        }
    }

    for (refs.items) |ref| {
        const exists = switch (ref.kind) {
            .ext => ext_ids.contains(ref.id),
            .sub => sub_ids.contains(ref.id),
        };
        if (!exists) {
            const kind = switch (ref.kind) {
                .ext => "dangling_ext_reference",
                .sub => "dangling_sub_reference",
            };
            const message = switch (ref.kind) {
                .ext => "ExtResource reference does not match any ext_resource id in file",
                .sub => "SubResource reference does not match any sub_resource id in file",
            };
            try report.add(allocator, .err, kind, message, null);
        }
    }

    try node_section_order.validateNodeParentOrder(&report, allocator, doc);

    const missing = scene_connections.missingEndpoints(allocator, doc) catch &.{};
    defer if (missing.len != 0) allocator.free(missing);
    for (missing) |endpoint| {
        const msg = try std.fmt.allocPrint(
            allocator,
            "connection {s}=\"{s}\" names a node that is not in the scene",
            .{ endpoint.field, endpoint.attr },
        );
        defer allocator.free(msg);
        try report.add(allocator, .err, "connection_node_missing", msg, endpoint.section_line);
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

    var report = try validateDocument(allocator, &doc, .{});
    defer report.deinit(allocator);

    try std.testing.expect(report.issues.items.len >= 1);
}

test "detect stale uid for path" {
    const allocator = std.testing.allocator;
    const file_bytes =
        \\[gd_scene format=3 uid="uid://a"]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    const source = file_bytes;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const ctx: ValidateContext = .{
        .project_name = "TestProject",
        .file_bytes = file_bytes,
        .resource_path = "res://test.tscn",
    };
    var report = try validateDocument(allocator, &doc, ctx);
    defer report.deinit(allocator);

    var found_stale = false;
    for (report.issues.items) |issue| {
        if (std.mem.eql(u8, issue.kind, "stale_uid_for_path")) found_stale = true;
    }
    try std.testing.expect(found_stale);
}

test "detect duplicate node unique_id" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[node name="A" type="Node" unique_id=42]
        \\[node name="B" type="Node" unique_id=42]
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var report = try validateDocument(allocator, &doc, .{});
    defer report.deinit(allocator);

    try std.testing.expect(hasErrors(&report));
}

test "detect dangling ext resource reference" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\[node name="Root" type="Node"]
        \\script = ExtResource("missing_id")
        \\
    ;

    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    var report = try validateDocument(allocator, &doc, .{});
    defer report.deinit(allocator);

    try std.testing.expect(hasErrors(&report));
}
