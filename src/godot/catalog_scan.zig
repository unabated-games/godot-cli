//! Discover and parse `PowerAICatalogManifest` `.tres` files in a Godot project.

const std = @import("std");
const document = @import("text_format/document.zig");
const property_line = @import("variant/property_line.zig");
const parse = @import("variant/parse.zig");
const Value = @import("variant/value.zig").Value;
const project_config = @import("project_config.zig");
const resource_uid = @import("resource_uid.zig");
const uid_cache = @import("uid_cache.zig");

pub const manifest_script_class = "PowerAICatalogManifest";
pub const catalog_format_version_supported: i64 = 1;

pub const IssueSeverity = enum {
    @"error",
    warning,
    info,

    pub fn jsonString(self: IssueSeverity) []const u8 {
        return switch (self) {
            .@"error" => "error",
            .warning => "warning",
            .info => "info",
        };
    }
};

pub const Issue = struct {
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
};

pub const DocRow = struct {
    name: []const u8 = "",
    doc: []const u8 = "",
    connect_example: []const u8 = "",
    when_to_call: []const u8 = "",

    pub fn deinit(self: *DocRow, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.doc);
        allocator.free(self.connect_example);
        allocator.free(self.when_to_call);
    }
};

pub const ManifestEntry = struct {
    manifest_path: []const u8,
    manifest_res_path: ?[]const u8 = null,
    catalog_format_version: i64 = 1,
    id: []const u8 = "",
    uid: []const u8 = "",
    scene: []const u8 = "",
    scene_uid: []const u8 = "",
    tags: []const []const u8 = &.{},
    summary: []const u8 = "",
    when_to_use: []const u8 = "",
    when_not_to_use: []const u8 = "",
    related_ids: []const []const u8 = &.{},
    prefer_over_ids: []const []const u8 = &.{},
    notes: []const u8 = "",
    export_root_script: []const u8 = "",
    signal_docs: []DocRow = &.{},
    function_docs: []DocRow = &.{},
    issues: []Issue = &.{},
    valid: bool = false,

    pub fn deinit(self: *ManifestEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.manifest_path);
        if (self.manifest_res_path) |path| allocator.free(path);
        allocator.free(self.id);
        allocator.free(self.uid);
        allocator.free(self.scene);
        allocator.free(self.scene_uid);
        for (self.tags) |tag| allocator.free(tag);
        allocator.free(self.tags);
        allocator.free(self.summary);
        allocator.free(self.when_to_use);
        allocator.free(self.when_not_to_use);
        for (self.related_ids) |item| allocator.free(item);
        allocator.free(self.related_ids);
        for (self.prefer_over_ids) |item| allocator.free(item);
        allocator.free(self.prefer_over_ids);
        allocator.free(self.notes);
        allocator.free(self.export_root_script);
        for (self.signal_docs) |*row| row.deinit(allocator);
        allocator.free(self.signal_docs);
        for (self.function_docs) |*row| row.deinit(allocator);
        allocator.free(self.function_docs);
        for (self.issues) |issue| {
            allocator.free(issue.code);
            allocator.free(issue.message);
        }
        allocator.free(self.issues);
    }
};

pub const ScanResult = struct {
    project_root: []const u8,
    tres_files_scanned: usize = 0,
    manifest_files_found: usize = 0,
    entries: []ManifestEntry,

    pub fn deinit(self: *ScanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.project_root);
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
    }
};

pub fn findValidEntryById(entries: []ManifestEntry, id: []const u8) ?*ManifestEntry {
    for (entries) |*entry| {
        if (entry.valid and std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

pub const ScanError = error{
    Io,
    OutOfMemory,
    ProjectRootRequired,
    InvalidProjectRoot,
};

pub fn scanProject(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    cache: ?*const uid_cache.Cache,
) ScanError!ScanResult {
    const norm_root = std.fs.path.resolve(allocator, &.{project_root}) catch return error.Io;
    errdefer allocator.free(norm_root);
    errdefer allocator.free(norm_root);

    const project_file = try std.fs.path.join(allocator, &.{ norm_root, "project.godot" });
    defer allocator.free(project_file);
    std.Io.Dir.cwd().access(io, project_file, .{}) catch return error.InvalidProjectRoot;

    var tres_paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (tres_paths.items) |path| allocator.free(path);
        tres_paths.deinit(allocator);
    }
    try collectTresFiles(allocator, io, norm_root, norm_root, &tres_paths);

    var entries: std.ArrayList(ManifestEntry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    var manifest_count: usize = 0;
    for (tres_paths.items) |path| {
        var doc = document.parseFile(allocator, io, path) catch continue;
        defer doc.deinit(allocator);

        if (!isPowerAiManifest(&doc)) continue;
        manifest_count += 1;

        const entry = try parseManifest(allocator, io, norm_root, cache, path, &doc);
        try entries.append(allocator, entry);
    }

    try validateCollected(allocator, entries.items);

    const owned_root = try allocator.dupe(u8, norm_root);
    allocator.free(norm_root);
    const slice = try entries.toOwnedSlice(allocator);

    return .{
        .project_root = owned_root,
        .tres_files_scanned = tres_paths.items.len,
        .manifest_files_found = manifest_count,
        .entries = slice,
    };
}

fn openDirAt(io: std.Io, path: []const u8) ScanError!std.Io.Dir {
    if (std.fs.path.isAbsolute(path)) {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return error.Io;
    }
    return std.Io.Dir.cwd().openDir(io, path, .{ .iterate = true }) catch return error.Io;
}

fn collectTresFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) ScanError!void {
    var dir = try openDirAt(io, dir_path);
    defer dir.close(io);

    var it = dir.iterate();
    while (true) {
        const next = it.next(io) catch return error.Io;
        const entry = next orelse break;
        if (entry.name.len > 0 and entry.name[0] == '.') continue;
        const child_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });
        errdefer allocator.free(child_path);

        switch (entry.kind) {
            .directory => {
                if (std.mem.eql(u8, entry.name, ".godot")) {
                    allocator.free(child_path);
                    continue;
                }
                try collectTresFiles(allocator, io, project_root, child_path, out);
                allocator.free(child_path);
            },
            .file => {
                if (!std.mem.endsWith(u8, entry.name, ".tres")) {
                    allocator.free(child_path);
                    continue;
                }
                const owned = child_path;
                try out.append(allocator, owned);
            },
            else => allocator.free(child_path),
        }
    }
}

fn isPowerAiManifest(doc: *const document.Document) bool {
    const header = doc.sections.items[0].header;
    if (!std.mem.eql(u8, header.name, "gd_resource")) return false;
    const script_class = header.getString("script_class") orelse return false;
    return std.mem.eql(u8, script_class, manifest_script_class);
}

fn parseManifest(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    cache: ?*const uid_cache.Cache,
    manifest_path: []const u8,
    doc: *const document.Document,
) ScanError!ManifestEntry {
    const resource_index = document.findSectionIndexByTagName(doc, "resource") orelse return error.OutOfMemory;
    const resource = &doc.sections.items[resource_index];

    var entry: ManifestEntry = .{
        .manifest_path = try allocator.dupe(u8, manifest_path),
    };
    errdefer entry.deinit(allocator);

    entry.manifest_res_path = try project_config.filesystemToResPath(allocator, project_root, manifest_path);
    entry.catalog_format_version = try readIntProperty(allocator, resource, "catalog_format_version") orelse 1;
    entry.id = try readStringProperty(allocator, resource, "id");
    entry.uid = try readStringProperty(allocator, resource, "uid");
    entry.scene = try readSceneProperty(allocator, resource, cache);
    entry.scene_uid = try readStringProperty(allocator, resource, "scene_uid");
    entry.tags = try readStringListProperty(allocator, resource, "tags");
    entry.summary = try readStringProperty(allocator, resource, "summary");
    entry.when_to_use = try readStringProperty(allocator, resource, "when_to_use");
    entry.when_not_to_use = try readStringProperty(allocator, resource, "when_not_to_use");
    entry.related_ids = try readStringListProperty(allocator, resource, "related_ids");
    entry.prefer_over_ids = try readStringListProperty(allocator, resource, "prefer_over_ids");
    entry.notes = try readStringProperty(allocator, resource, "notes");
    entry.export_root_script = try readStringProperty(allocator, resource, "export_root_script");
    entry.signal_docs = try readDocRowsProperty(allocator, resource, "signal_docs", true);
    entry.function_docs = try readDocRowsProperty(allocator, resource, "function_docs", false);

    var issues: std.ArrayList(Issue) = .empty;
    errdefer freeIssues(allocator, &issues);

    if (entry.catalog_format_version != catalog_format_version_supported) {
        try appendIssue(allocator, &issues, .@"error", "unsupported_format_version", "catalog_format_version must be 1");
    }
    if (entry.id.len == 0) try appendIssue(allocator, &issues, .@"error", "missing_id", "catalog id is required");
    if (entry.uid.len == 0) try appendIssue(allocator, &issues, .@"error", "missing_uid", "manifest uid is required");
    if (entry.scene.len == 0) {
        try appendIssue(allocator, &issues, .@"error", "missing_scene", "scene path is required");
    } else if (!std.mem.startsWith(u8, entry.scene, "res://")) {
        try appendIssue(allocator, &issues, .@"error", "invalid_scene_path", "scene must be a res:// path");
    } else if (try project_config.resPathToFilesystem(allocator, project_root, entry.scene)) |fs_path| {
        defer allocator.free(fs_path);
        std.Io.Dir.cwd().access(io, fs_path, .{}) catch {
            try appendIssue(allocator, &issues, .@"error", "scene_not_found", "scene file does not exist under project root");
        };
        const header_uid = readSceneHeaderUid(allocator, io, fs_path) catch null;
        if (header_uid) |uid_text| {
            defer allocator.free(uid_text);
            if (entry.scene_uid.len == 0) {
                const copy = try allocator.dupe(u8, uid_text);
                allocator.free(entry.scene_uid);
                entry.scene_uid = copy;
            } else if (!std.mem.eql(u8, entry.scene_uid, uid_text)) {
                try appendIssue(allocator, &issues, .warning, "scene_uid_mismatch", "scene_uid does not match scene file header");
            }
        }
    } else {
        try appendIssue(allocator, &issues, .@"error", "invalid_scene_path", "scene path could not be resolved under project root");
    }

    if (entry.summary.len == 0) try appendIssue(allocator, &issues, .warning, "missing_summary", "summary is empty");
    if (entry.tags.len == 0) try appendIssue(allocator, &issues, .warning, "missing_tags", "tags are empty");
    if (entry.when_to_use.len == 0) try appendIssue(allocator, &issues, .warning, "missing_when_to_use", "when_to_use is empty");

    entry.issues = try issues.toOwnedSlice(allocator);
    entry.valid = !hasErrorIssues(entry.issues);
    return entry;
}

fn validateCollected(allocator: std.mem.Allocator, entries: []ManifestEntry) ScanError!void {
    for (entries, 0..) |*entry, i| {
        for (entries[i + 1 ..]) |*other| {
            if (entry.id.len > 0 and std.mem.eql(u8, entry.id, other.id)) {
                try pushIssue(allocator, entry, .@"error", "duplicate_id", "duplicate catalog id");
                try pushIssue(allocator, other, .@"error", "duplicate_id", "duplicate catalog id");
            }
            if (entry.scene.len > 0 and std.mem.eql(u8, entry.scene, other.scene)) {
                try pushIssue(allocator, entry, .@"error", "duplicate_scene", "multiple manifests reference the same scene");
                try pushIssue(allocator, other, .@"error", "duplicate_scene", "multiple manifests reference the same scene");
            }
        }
    }
}

fn pushIssue(
    allocator: std.mem.Allocator,
    entry: *ManifestEntry,
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
) ScanError!void {
    var issues: std.ArrayList(Issue) = .empty;
    errdefer freeIssues(allocator, &issues);

    // Copying the Issue structs moves their `code`/`message` allocations to the
    // new list — only the old backing array is this function's to free. Freeing
    // the strings here would leave every pre-existing issue dangling, which is
    // precisely the case this runs in: an entry that already has warnings and
    // then turns out to be a duplicate.
    try issues.ensureTotalCapacity(allocator, entry.issues.len + 1);
    issues.appendSliceAssumeCapacity(entry.issues);
    const old_array = entry.issues;
    entry.issues = &.{};
    allocator.free(old_array);

    try appendIssue(allocator, &issues, severity, code, message);
    entry.issues = try issues.toOwnedSlice(allocator);
    entry.valid = !hasErrorIssues(entry.issues);
}

fn hasErrorIssues(issues: []const Issue) bool {
    for (issues) |issue| {
        if (issue.severity == .@"error") return true;
    }
    return false;
}

fn appendIssue(
    allocator: std.mem.Allocator,
    issues: *std.ArrayList(Issue),
    severity: IssueSeverity,
    code: []const u8,
    message: []const u8,
) ScanError!void {
    try issues.append(allocator, .{
        .severity = severity,
        .code = try allocator.dupe(u8, code),
        .message = try allocator.dupe(u8, message),
    });
}

fn freeIssues(allocator: std.mem.Allocator, issues: *std.ArrayList(Issue)) void {
    for (issues.items) |issue| {
        allocator.free(issue.code);
        allocator.free(issue.message);
    }
    issues.deinit(allocator);
}

fn readSceneProperty(
    allocator: std.mem.Allocator,
    section: *const document.Section,
    cache: ?*const uid_cache.Cache,
) ScanError![]const u8 {
    const scene = try readStringProperty(allocator, section, "scene");
    if (scene.len > 0) {
        const resolved = try resolveSceneReference(allocator, scene, cache);
        allocator.free(scene);
        return resolved;
    }
    allocator.free(scene);
    return resolveSceneReference(allocator, try readStringProperty(allocator, section, "_scene_storage"), cache);
}

fn resolveSceneReference(
    allocator: std.mem.Allocator,
    reference: []const u8,
    cache: ?*const uid_cache.Cache,
) ScanError![]const u8 {
    if (reference.len == 0) return try allocator.dupe(u8, "");
    if (std.mem.startsWith(u8, reference, "res://")) return try allocator.dupe(u8, reference);
    if (std.mem.startsWith(u8, reference, "uid://")) {
        if (cache) |c| {
            const id = resource_uid.textToId(reference);
            if (id != resource_uid.invalid_id) {
                if (c.pathForId(id)) |path| return try allocator.dupe(u8, path);
            }
        }
        return try allocator.dupe(u8, reference);
    }
    return try allocator.dupe(u8, reference);
}

fn readSceneHeaderUid(allocator: std.mem.Allocator, io: std.Io, scene_path: []const u8) ScanError!?[]const u8 {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, scene_path, allocator, .unlimited) catch return null;
    defer allocator.free(bytes);
    var doc = document.parseBytes(allocator, bytes) catch return null;
    defer doc.deinit(allocator);
    if (doc.sections.items.len == 0) return null;
    const header = &doc.sections.items[0].header;
    if (!std.mem.eql(u8, header.name, "gd_scene")) return null;
    if (header.getString("uid")) |uid_text| return try allocator.dupe(u8, uid_text);
    return null;
}

fn readStringProperty(allocator: std.mem.Allocator, section: *const document.Section, name: []const u8) ScanError![]const u8 {
    if (try readPropertyValue(allocator, section, name)) |value| {
        defer value.deinit(allocator);
        if (valueAsString(&value)) |text| return try allocator.dupe(u8, text);
    }
    return try allocator.dupe(u8, "");
}

fn readIntProperty(allocator: std.mem.Allocator, section: *const document.Section, name: []const u8) ScanError!?i64 {
    if (try readPropertyValue(allocator, section, name)) |value| {
        defer value.deinit(allocator);
        return switch (value.kind) {
            .integer => value.integer,
            .float => @intFromFloat(value.float_val),
            else => null,
        };
    }
    return null;
}

fn readStringListProperty(allocator: std.mem.Allocator, section: *const document.Section, name: []const u8) ScanError![]const []const u8 {
    if (try readPropertyValue(allocator, section, name)) |value| {
        defer value.deinit(allocator);
        return try valueToStringSlice(allocator, &value);
    }
    return &.{};
}

fn readDocRowsProperty(
    allocator: std.mem.Allocator,
    section: *const document.Section,
    name: []const u8,
    is_signal: bool,
) ScanError![]DocRow {
    if (try readPropertyValue(allocator, section, name)) |value| {
        defer value.deinit(allocator);
        return try valueToDocRows(allocator, &value, is_signal);
    }
    return &.{};
}

fn readPropertyValue(allocator: std.mem.Allocator, section: *const document.Section, name: []const u8) ScanError!?Value {
    const raw = try readPropertyRaw(allocator, section, name) orelse return null;
    defer allocator.free(raw);
    return parse.parsePropertyValue(allocator, raw) catch return null;
}

fn readPropertyRaw(allocator: std.mem.Allocator, section: *const document.Section, name: []const u8) ScanError!?[]const u8 {
    var start_index: ?usize = null;
    for (section.properties.items, 0..) |prop, index| {
        const split = property_line.splitPropertyLine(prop.raw) orelse continue;
        if (std.mem.eql(u8, split.name, name)) {
            start_index = index;
            break;
        }
    }
    const start = start_index orelse return null;

    const first = section.properties.items[start];
    const eq = std.mem.indexOf(u8, first.raw, " = ") orelse return null;
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, std.mem.trim(u8, first.raw[eq + 3 ..], &std.ascii.whitespace));

    for (section.properties.items[start + 1 ..]) |prop| {
        if (property_line.splitPropertyLine(prop.raw) != null) break;
        if (buf.items.len > 0) try buf.append(allocator, ' ');
        try buf.appendSlice(allocator, std.mem.trim(u8, prop.raw, &std.ascii.whitespace));
    }

    return try buf.toOwnedSlice(allocator);
}

fn valueAsString(value: *const Value) ?[]const u8 {
    return switch (value.kind) {
        .string, .string_name, .node_path, .resource => value.string,
        else => null,
    };
}

fn valueToStringSlice(allocator: std.mem.Allocator, value: *const Value) ScanError![]const []const u8 {
    var items: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (items.items) |item| allocator.free(item);
        items.deinit(allocator);
    }

    const elements = valueElements(value) orelse return &.{};
    for (elements) |*element| {
        if (valueAsString(element)) |text| {
            try items.append(allocator, try allocator.dupe(u8, text));
        }
    }
    return try items.toOwnedSlice(allocator);
}

fn valueElements(value: *const Value) ?[]const Value {
    return switch (value.kind) {
        .array => value.elements,
        .packed_array => value.elements,
        .typed_array => value.elements,
        else => null,
    };
}

fn valueToDocRows(allocator: std.mem.Allocator, value: *const Value, is_signal: bool) ScanError![]DocRow {
    var rows: std.ArrayList(DocRow) = .empty;
    errdefer {
        for (rows.items) |*row| row.deinit(allocator);
        rows.deinit(allocator);
    }

    const elements = valueElements(value) orelse return &.{};
    for (elements) |*element| {
        if (element.kind != .dictionary and element.kind != .typed_dictionary) continue;
        const entries = element.entries orelse continue;
        var row: DocRow = .{
            .name = try allocator.dupe(u8, ""),
            .doc = try allocator.dupe(u8, ""),
            .connect_example = try allocator.dupe(u8, ""),
            .when_to_call = try allocator.dupe(u8, ""),
        };
        for (entries) |*entry_item| {
            const key = entry_item.key;
            const text = valueAsString(&entry_item.value) orelse "";
            if (std.mem.eql(u8, key, "name")) {
                allocator.free(row.name);
                row.name = try allocator.dupe(u8, text);
            } else if (std.mem.eql(u8, key, "doc")) {
                allocator.free(row.doc);
                row.doc = try allocator.dupe(u8, text);
            } else if (std.mem.eql(u8, key, "connect_example")) {
                allocator.free(row.connect_example);
                row.connect_example = try allocator.dupe(u8, text);
            } else if (std.mem.eql(u8, key, "when_to_call")) {
                allocator.free(row.when_to_call);
                row.when_to_call = try allocator.dupe(u8, text);
            }
        }
        if (row.name.len == 0 and row.doc.len == 0 and row.connect_example.len == 0 and row.when_to_call.len == 0) {
            row.deinit(allocator);
            continue;
        }
        _ = is_signal;
        try rows.append(allocator, row);
    }

    return try rows.toOwnedSlice(allocator);
}

test "scan button manifest fixture" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var result = try scanProject(allocator, io, "test_fixtures/project", null);
    defer result.deinit(allocator);

    try std.testing.expect(result.manifest_files_found >= 1);
    try std.testing.expect(result.entries.len >= 1);

    const entry = blk: {
        for (result.entries) |*item| {
            if (std.mem.eql(u8, item.id, "ui/button")) break :blk item;
        }
        return error.TestExpectedEqual;
    };

    try std.testing.expectEqualStrings("ui/button", entry.id);
    try std.testing.expectEqualStrings("res://ui/button/button.tscn", entry.scene);
    try std.testing.expect(entry.valid);
    try std.testing.expect(entry.tags.len == 3);
    try std.testing.expect(entry.signal_docs.len == 1);
    try std.testing.expectEqualStrings("button_pressed", entry.signal_docs[0].name);
}
