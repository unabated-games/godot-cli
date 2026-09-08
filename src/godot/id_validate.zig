//! Validation helpers for Godot resource UIDs and scene-local IDs.
//! Foundation for a future `validate` / detection command (LLM or manual edit checks).

const std = @import("std");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");
const project_config = @import("project_config.zig");
const document = @import("text_format/document.zig");
const class_info = @import("class_info.zig");
const gdscript_scan = @import("gdscript_scan.zig");
const node_section_order = @import("node_section_order.zig");
const scene_connections = @import("scene_connections.zig");
const resource_uid_lookup = @import("resource_uid_lookup.zig");

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

    const declared = resource_uid.textToId(uid_text);

    // A scene or resource carries its uid in its own header; that is the
    // value to compare, never a hash of the file. `scene new` stamps a random
    // one, as the editor does, so a hash would always disagree.
    if (std.mem.endsWith(u8, res_path, ".tscn") or std.mem.endsWith(u8, res_path, ".tres")) {
        const header_uid = (resource_uid_lookup.readSceneUidFromResPath(allocator, io, project_root, res_path) catch null) orelse return;
        defer allocator.free(header_uid);
        if (declared != resource_uid.textToId(header_uid)) {
            try report.add(
                allocator,
                .warning,
                "stale_uid_for_path",
                "ext_resource uid does not match the uid in the referenced file's header; scene normalize repairs it",
                line,
            );
        }
        return;
    }

    // A `.uid` sidecar is the UID Godot assigned and will keep; the file's
    // bytes changing afterwards does not change it. Only without a sidecar is
    // the derived value the right comparison.
    if (resource_uid_lookup.readSidecarUid(allocator, io, fs_path_owned)) |sidecar| {
        defer allocator.free(sidecar);
        if (declared != resource_uid.textToId(sidecar)) {
            try report.add(
                allocator,
                .warning,
                "stale_uid_for_path",
                "ext_resource uid does not match the .uid sidecar Godot assigned to the referenced file",
                line,
            );
        }
        return;
    }

    const ext_bytes = std.Io.Dir.cwd().readFileAlloc(io, fs_path_owned, allocator, .unlimited) catch return;
    defer allocator.free(ext_bytes);

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
                    // The header uid is assigned when the scene is first saved
                    // and kept through every edit, so it is checked against the
                    // project's uid cache rather than recomputed from bytes.
                    if (ctx.cache) |c| {
                        if (ctx.resource_path) |resource_path| {
                            if (c.idForPath(resource_path)) |cached| {
                                if (cached != resource_uid.textToId(uid_text)) {
                                    try report.add(allocator, .warning, "stale_uid_for_path", "scene uid does not match the project's uid_cache.bin entry for this path", section.line);
                                }
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
                                    "ext_resource uid maps to a different path in uid_cache.bin; after moving files the cache is stale until Godot imports again (godot --headless --path . --import --quit)",
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

    try warnControlsUnderNode2D(allocator, doc, &report);
    try checkPropertyTypes(allocator, doc, &report);
    try checkConnectionSignals(allocator, doc, ctx, &report);
    return report;
}

/// A Control whose parent is a Node2D has no rect to anchor to, so full-rect
/// anchors give it zero size. Trials 17 and 18 each lost a run to it. Only
/// nodes whose type is a known Control class are checked; instanced nodes
/// have no type here.
fn warnControlsUnderNode2D(allocator: std.mem.Allocator, doc: *const document.Document, report: *Report) !void {
    const node_tree = @import("node_tree.zig");
    var list = node_tree.collectNodes(allocator, doc) catch return;
    defer list.deinit(allocator);
    for (list.nodes) |*node| {
        if (!isControlClass(node.node_type)) continue;
        if (node.parent.len == 0) continue;
        const last = std.mem.lastIndexOfScalar(u8, node.path, '/') orelse continue;
        const parent = node_tree.findByPath(&list, node.path[0..last]) orelse continue;
        if (!isNode2DClass(parent.node_type)) continue;
        try report.add(allocator, .warning, "control_under_node2d", "a Control under a Node2D has no parent rect, so anchors give it no size and it may draw nothing; put UI under a CanvasLayer or another Control", node.section_line);
    }
}

fn isControlClass(name: []const u8) bool {
    return class_info.descendsFrom(name, "Control");
}

fn isNode2DClass(name: []const u8) bool {
    return class_info.descendsFrom(name, "Node2D");
}

/// A signal a node's class does not emit connects cleanly and fails only when
/// the game runs: `pressd` for `pressed` costs a whole run to find. Trial 19
/// asked for this.
///
/// A node carrying a script is left alone, because a script may declare its
/// own signals and this check cannot see the file from here; `scene
/// connection add` does read the script when it has the project root.
fn checkConnectionSignals(allocator: std.mem.Allocator, doc: *const document.Document, ctx: ValidateContext, report: *Report) !void {
    const node_tree = @import("node_tree.zig");
    var list = node_tree.collectNodes(allocator, doc) catch return;
    defer list.deinit(allocator);

    for (doc.sections.items) |*section| {
        if (!std.mem.eql(u8, section.header.name, "connection")) continue;
        const signal = section.header.getString("signal") orelse continue;
        const from = section.header.getString("from") orelse continue;

        const path = if (std.mem.eql(u8, from, "."))
            list.nodes[0].path
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ list.nodes[0].path, from });
        defer if (!std.mem.eql(u8, from, ".")) allocator.free(path);

        const node = node_tree.findByPath(&list, path) orelse continue;
        // An instanced node's class lives in the other scene.
        if (node.instance != null) continue;

        const known = class_info.hasSignal(node.node_type, signal) orelse continue;
        if (known) continue;

        // The class does not emit it, so the node's script is the remaining
        // way it could be real. Read the script when the caller gave a
        // project root; without one, a scripted node stays exempt.
        if (scriptOf(doc, node.section_index)) |script_ref| {
            switch (scriptDeclaresSignal(allocator, doc, ctx, script_ref, signal)) {
                .declares => continue,
                .unreadable => continue,
                .absent => {},
            }
        }

        const msg = try std.fmt.allocPrint(
            allocator,
            "{s} does not emit a signal named {s}, and its script does not declare one either, so this connection never fires; check the spelling, or add `signal {s}` to the script",
            .{ node.node_type, signal, signal },
        );
        defer allocator.free(msg);
        try report.add(allocator, .err, "unknown_signal", msg, section.line);
    }
}

fn section_for(doc: *const document.Document, index: usize) ?*const document.Section {
    if (index >= doc.sections.items.len) return null;
    return &doc.sections.items[index];
}

/// The raw value of the node's `script` property, e.g. `ExtResource("Script_main")`.
fn scriptOf(doc: *const document.Document, section_index: usize) ?[]const u8 {
    if (section_index >= doc.sections.items.len) return null;
    for (doc.sections.items[section_index].properties.items) |line| {
        const equals = std.mem.indexOfScalar(u8, line.raw, '=') orelse continue;
        if (!std.mem.eql(u8, std.mem.trim(u8, line.raw[0..equals], " \t"), "script")) continue;
        return std.mem.trim(u8, line.raw[equals + 1 ..], " \t");
    }
    return null;
}

const SignalInScript = enum { declares, absent, unreadable };

/// Whether the GDScript the node carries declares the signal itself. A script
/// can add signals its class never had, which is why a scripted node used to
/// be skipped wholesale; reading the file turns that exemption into an answer.
fn scriptDeclaresSignal(
    allocator: std.mem.Allocator,
    doc: *const document.Document,
    ctx: ValidateContext,
    script_ref: []const u8,
    signal: []const u8,
) SignalInScript {
    const root = ctx.project_root orelse return .unreadable;
    const io = ctx.io orelse return .unreadable;

    // script = ExtResource("Script_main") -> the section with that id.
    const open_quote = std.mem.indexOfScalar(u8, script_ref, '"') orelse return .unreadable;
    const rest = script_ref[open_quote + 1 ..];
    const close_quote = std.mem.indexOfScalar(u8, rest, '"') orelse return .unreadable;
    const id = rest[0..close_quote];

    var res_path: ?[]const u8 = null;
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "ext_resource")) continue;
        const section_id = section.header.getString("id") orelse continue;
        if (!std.mem.eql(u8, section_id, id)) continue;
        res_path = section.header.getString("path");
        break;
    }
    const path = res_path orelse return .unreadable;
    if (!std.mem.startsWith(u8, path, "res://")) return .unreadable;

    const full = std.fs.path.join(allocator, &.{ root, path["res://".len..] }) catch return .unreadable;
    defer allocator.free(full);
    const source = std.Io.Dir.cwd().readFileAlloc(io, full, allocator, .limited(4 * 1024 * 1024)) catch return .unreadable;
    defer allocator.free(source);

    var interface = gdscript_scan.parseScript(allocator, source) catch return .unreadable;
    defer interface.deinit(allocator);
    for (interface.signals) |declared| {
        if (std.mem.eql(u8, declared.name, signal)) return .declares;
    }
    return .absent;
}

/// A property whose value is the wrong Variant type for its class passes
/// every other check and runs: Godot coerces it, and only the frame shows the
/// damage. Trials 17, 18 and 19 each asked for this.
///
/// Conservative by construction: a class the table does not carry, a property
/// it does not declare (theme overrides, a script's exports, `metadata/*`),
/// and a value that does not parse are all left alone, because a false report
/// on a correct scene costs more than a missed one.
fn checkPropertyTypes(allocator: std.mem.Allocator, doc: *const document.Document, report: *Report) !void {
    const variant_parse = @import("variant/parse.zig");
    for (doc.sections.items) |*section| {
        // Nodes, and the resources beside them: a sub_resource's bg_color is
        // as wrong as a node's, and both carry their class in `type`.
        const is_node = std.mem.eql(u8, section.header.name, "node");
        const is_resource = std.mem.eql(u8, section.header.name, "sub_resource") or
            std.mem.eql(u8, section.header.name, "resource");
        if (!is_node and !is_resource) continue;
        const node_type = section.header.getString("type") orelse continue;
        if (class_info.findClass(node_type) == null) continue;

        for (section.properties.items) |line| {
            const equals = std.mem.indexOfScalar(u8, line.raw, '=') orelse continue;
            const name = std.mem.trim(u8, line.raw[0..equals], " \t");
            const value_text = std.mem.trim(u8, line.raw[equals + 1 ..], " \t");
            if (name.len == 0 or value_text.len == 0) continue;

            const property = class_info.findProperty(node_type, name) orelse continue;
            if (property.kinds.len == 0) continue;

            var value = variant_parse.parsePropertyValue(allocator, value_text) catch continue;
            defer value.deinit(allocator);
            const kind = @tagName(value.kind);
            if (class_info.kindFits(property, kind)) continue;

            const msg = try std.fmt.allocPrint(
                allocator,
                "{s}.{s} is {s}, and this value is {s}: Godot coerces it and the file still loads, so only the running frame shows the damage",
                .{ node_type, name, property.type_name, kind },
            );
            defer allocator.free(msg);
            try report.add(allocator, .err, "property_type_mismatch", msg, section.line);
        }
    }
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

test "an edited scene keeps its uid: no stale warning without a cache entry" {
    // The header uid is assigned once by Godot and survives edits. Recomputing
    // it from the current bytes, as this check once did, flagged every edited
    // scene as stale.
    const allocator = std.testing.allocator;
    const file_bytes =
        \\[gd_scene format=3 uid="uid://a"]
        \\
        \\[node name="Root" type="Node"]
        \\
    ;
    var doc = try document.parseBytes(allocator, file_bytes);
    defer doc.deinit(allocator);

    const ctx: ValidateContext = .{
        .project_name = "TestProject",
        .file_bytes = file_bytes,
        .resource_path = "res://test.tscn",
    };
    var report = try validateDocument(allocator, &doc, ctx);
    defer report.deinit(allocator);

    for (report.issues.items) |issue| {
        try std.testing.expect(!std.mem.eql(u8, issue.kind, "stale_uid_for_path"));
    }
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

test "a property whose value is the wrong type for its class is an error" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Control"]
        \\visible = Vector2(1, 2)
        \\anchor_right = 1.0
        \\anchor_bottom = 1
        \\
        \\[node name="Score" type="Label" parent="."]
        \\text = 5
        \\theme_override_font_sizes/font_size = 32
        \\metadata/level = "one"
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);
    var report = try validateDocument(allocator, &doc, .{});
    defer report.deinit(allocator);

    var mismatches: usize = 0;
    for (report.issues.items) |issue| {
        if (std.mem.eql(u8, issue.kind, "property_type_mismatch")) mismatches += 1;
    }
    // visible (bool <- Vector2) and text (String <- int). A whole float
    // written as an integer is how Godot writes it, a theme override is not a
    // class property, and metadata is free-form: none of those is a mismatch.
    try std.testing.expectEqual(@as(usize, 2), mismatches);
}

test "a connection to a signal the class does not emit is an error" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Control"]
        \\
        \\[node name="Play" type="Button" parent="."]
        \\
        \\[connection signal="pressed" from="Play" to="." method="_on_play_pressed"]
        \\[connection signal="mouse_entered" from="Play" to="." method="_on_hover"]
        \\[connection signal="pressd" from="Play" to="." method="_on_typo"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);
    var report = try validateDocument(allocator, &doc, .{});
    defer report.deinit(allocator);

    var unknown: usize = 0;
    for (report.issues.items) |issue| {
        if (std.mem.eql(u8, issue.kind, "unknown_signal")) unknown += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), unknown);
}

test "a scripted node's connection is left alone, since a script declares signals" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://main.gd" id="Script_main"]
        \\
        \\[node name="Main" type="Control"]
        \\
        \\[node name="Spawner" type="Node2D" parent="."]
        \\script = ExtResource("Script_main")
        \\
        \\[connection signal="wave_finished" from="Spawner" to="." method="_on_wave"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);
    var report = try validateDocument(allocator, &doc, .{});
    defer report.deinit(allocator);

    for (report.issues.items) |issue| {
        try std.testing.expect(!std.mem.eql(u8, issue.kind, "unknown_signal"));
    }
}
