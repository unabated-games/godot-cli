//! Render agent-facing markdown digests from catalog scan + show data.

const std = @import("std");
const catalog_scan = @import("catalog_scan.zig");
const catalog_builtins = @import("catalog_builtins.zig");
const catalog_show = @import("catalog_show.zig");
const uid_cache = @import("uid_cache.zig");
const io_util = @import("../io_util.zig");

pub const ExportResult = struct {
    project_root: []const u8,
    output_path: []const u8,
    markdown: []const u8,
    project_entry_count: usize,
    builtin_entry_count: usize,
    skipped_invalid_count: usize,
    wrote_file: bool,

    pub fn deinit(self: *ExportResult, allocator: std.mem.Allocator) void {
        allocator.free(self.project_root);
        allocator.free(self.output_path);
        allocator.free(self.markdown);
    }
};

pub const ExportError = catalog_show.ShowError;

pub fn exportCatalog(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: []const u8,
    cache: ?*const uid_cache.Cache,
    output_path: []const u8,
    dry_run: bool,
) ExportError!ExportResult {
    var scan = try catalog_scan.scanProject(allocator, io, project_root, cache);
    defer scan.deinit(allocator);

    var project_shown: std.ArrayList(catalog_show.ShowResult) = .empty;
    defer {
        for (project_shown.items) |*shown| shown.deinit(allocator);
        project_shown.deinit(allocator);
    }

    var skipped_invalid: usize = 0;
    var valid_ids: std.ArrayList([]const u8) = .empty;
    defer {
        for (valid_ids.items) |id| allocator.free(id);
        valid_ids.deinit(allocator);
    }

    for (scan.entries) |*entry| {
        if (!entry.valid) {
            skipped_invalid += 1;
            continue;
        }
        try valid_ids.append(allocator, try allocator.dupe(u8, entry.id));
    }

    std.mem.sort([]const u8, valid_ids.items, {}, compareIds);
    for (valid_ids.items) |id| {
        const entry = findEntryById(scan.entries, id) orelse continue;
        try project_shown.append(allocator, try catalog_show.showManifestEntry(
            allocator,
            io,
            scan.project_root,
            cache,
            entry,
        ));
    }

    const builtins = try catalog_builtins.allEntries(allocator);
    defer catalog_builtins.freeEntries(allocator, builtins);

    var builtin_shown: std.ArrayList(catalog_show.ShowResult) = .empty;
    defer {
        for (builtin_shown.items) |*shown| shown.deinit(allocator);
        builtin_shown.deinit(allocator);
    }

    var builtin_ids: std.ArrayList([]const u8) = .empty;
    defer builtin_ids.deinit(allocator);
    for (builtins) |entry| try builtin_ids.append(allocator, entry.id);
    std.mem.sort([]const u8, builtin_ids.items, {}, compareIds);

    for (builtin_ids.items) |id| {
        const builtin = try catalog_builtins.findById(allocator, id) orelse return error.InvalidBuiltinCatalog;
        try builtin_shown.append(allocator, try showBuiltinForExport(allocator, builtin));
    }

    const markdown = try renderMarkdown(allocator, project_shown.items, builtin_shown.items);
    errdefer allocator.free(markdown);

    var wrote_file = false;
    if (!dry_run) {
        io_util.writeFileAtomic(io, output_path, markdown) catch return error.Io;
        wrote_file = true;
    }

    return .{
        .project_root = try allocator.dupe(u8, scan.project_root),
        .output_path = try allocator.dupe(u8, output_path),
        .markdown = markdown,
        .project_entry_count = project_shown.items.len,
        .builtin_entry_count = builtin_shown.items.len,
        .skipped_invalid_count = skipped_invalid,
        .wrote_file = wrote_file,
    };
}

fn showBuiltinForExport(allocator: std.mem.Allocator, builtin: catalog_builtins.BuiltinEntry) ExportError!catalog_show.ShowResult {
    var signals: std.ArrayList(catalog_show.MergedSignal) = .empty;
    errdefer {
        for (signals.items) |*item| item.deinit(allocator);
        signals.deinit(allocator);
    }
    for (builtin.signals) |signal_doc| {
        try signals.append(allocator, .{
            .name = try allocator.dupe(u8, signal_doc.name),
            .doc = try allocator.dupe(u8, signal_doc.doc),
            .doc_source = try allocator.dupe(u8, "builtin"),
        });
    }

    return .{
        .id = try allocator.dupe(u8, builtin.id),
        .source = try allocator.dupe(u8, "builtin"),
        .builtin = builtin,
        .exports_source = try allocator.dupe(u8, "builtin"),
        .signals = try signals.toOwnedSlice(allocator),
    };
}

fn compareIds(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn findEntryById(entries: []catalog_scan.ManifestEntry, id: []const u8) ?*catalog_scan.ManifestEntry {
    for (entries) |*entry| {
        if (std.mem.eql(u8, entry.id, id)) return entry;
    }
    return null;
}

fn renderMarkdown(
    allocator: std.mem.Allocator,
    project_entries: []const catalog_show.ShowResult,
    builtin_entries: []const catalog_show.ShowResult,
) ExportError![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "# Component Catalog\n\n");
    try out.appendSlice(allocator, "> Generated by `godot-cli catalog export`. Project entries reference PackedScenes; `godot/` builtins are document-only.\n");
    try out.appendSlice(allocator, "> Scene authoring guide: [agent_scene_authoring.md](../../docs/agent_scene_authoring.md)\n\n");

    try out.appendSlice(allocator, "## Project components\n\n");
    if (project_entries.len == 0) {
        try out.appendSlice(allocator, "_No valid project catalog entries found._\n\n");
    } else {
        for (project_entries) |*shown| {
            try appendProjectEntry(allocator, &out, shown);
        }
    }

    try out.appendSlice(allocator, "## Godot builtins\n\n");
    try out.appendSlice(allocator, "_Document-only references. Use raw node creation with the documented class name instead of instancing a project scene._\n\n");
    for (builtin_entries) |*shown| {
        try appendBuiltinEntry(allocator, &out, shown);
    }

    return try out.toOwnedSlice(allocator);
}

fn appendFmt(allocator: std.mem.Allocator, out: *std.ArrayList(u8), comptime fmt: []const u8, args: anytype) ExportError!void {
    const text = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(text);
    try out.appendSlice(allocator, text);
}

fn appendProjectEntry(allocator: std.mem.Allocator, out: *std.ArrayList(u8), shown: *const catalog_show.ShowResult) ExportError!void {
    const manifest = shown.manifest orelse return;
    try appendFmt(allocator, out, "### `{s}`\n\n", .{shown.id});
    try appendFmt(allocator, out, "- **Scene:** `{s}`\n", .{manifest.scene});
    if (manifest.tags.len > 0) {
        try out.appendSlice(allocator, "- **Tags:** ");
        for (manifest.tags, 0..) |tag, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, tag);
        }
        try out.appendSlice(allocator, "\n");
    }
    if (manifest.summary.len > 0) {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, manifest.summary);
        try out.appendSlice(allocator, "\n");
    }
    if (manifest.when_to_use.len > 0) {
        try appendFmt(allocator, out, "\n**When to use:** {s}\n", .{manifest.when_to_use});
    }
    if (manifest.when_not_to_use.len > 0) {
        try appendFmt(allocator, out, "\n**When not to use:** {s}\n", .{manifest.when_not_to_use});
    }
    if (manifest.notes.len > 0) {
        try appendFmt(allocator, out, "\n**Notes:** {s}\n", .{manifest.notes});
    }

    if (shown.exports.len > 0) {
        try out.appendSlice(allocator, "\n**Exports**\n\n");
        for (shown.exports) |*export_info| {
            try appendExportLine(allocator, out, export_info);
        }
    }

    if (shown.signals.len > 0) {
        try out.appendSlice(allocator, "\n**Signals**\n\n");
        for (shown.signals) |*signal_info| {
            try appendSignalLine(allocator, out, signal_info);
        }
    }

    if (manifest.related_ids.len > 0 or manifest.prefer_over_ids.len > 0) {
        try out.appendSlice(allocator, "\n");
        if (manifest.related_ids.len > 0) {
            try out.appendSlice(allocator, "**Related:** ");
            for (manifest.related_ids, 0..) |related, index| {
                if (index > 0) try out.appendSlice(allocator, ", ");
                try appendFmt(allocator, out, "`{s}`", .{related});
            }
            try out.appendSlice(allocator, "\n");
        }
        if (manifest.prefer_over_ids.len > 0) {
            try out.appendSlice(allocator, "**Prefer over:** ");
            for (manifest.prefer_over_ids, 0..) |related, index| {
                if (index > 0) try out.appendSlice(allocator, ", ");
                try appendFmt(allocator, out, "`{s}`", .{related});
            }
            try out.appendSlice(allocator, "\n");
        }
    }

    try out.appendSlice(allocator, "\n---\n\n");
}

fn appendBuiltinEntry(allocator: std.mem.Allocator, out: *std.ArrayList(u8), shown: *const catalog_show.ShowResult) ExportError!void {
    const builtin = shown.builtin orelse return;
    try appendFmt(allocator, out, "### `{s}`\n\n", .{shown.id});
    try appendFmt(allocator, out, "- **Class:** `{s}`\n", .{builtin.class_name});
    if (builtin.inherits.len > 0) {
        try appendFmt(allocator, out, "- **Inherits:** `{s}`\n", .{builtin.inherits});
    }
    if (builtin.tags.len > 0) {
        try out.appendSlice(allocator, "- **Tags:** ");
        for (builtin.tags, 0..) |tag, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, tag);
        }
        try out.appendSlice(allocator, "\n");
    }
    if (builtin.summary.len > 0) {
        try out.appendSlice(allocator, "\n");
        try out.appendSlice(allocator, builtin.summary);
        try out.appendSlice(allocator, "\n");
    }
    if (builtin.when_to_use.len > 0) {
        try appendFmt(allocator, out, "\n**When to use:** {s}\n", .{builtin.when_to_use});
    }
    if (builtin.when_not_to_use.len > 0) {
        try appendFmt(allocator, out, "\n**When not to use:** {s}\n", .{builtin.when_not_to_use});
    }
    if (shown.signals.len > 0) {
        try out.appendSlice(allocator, "\n**Signals**\n\n");
        for (shown.signals) |*signal_info| {
            try appendSignalLine(allocator, out, signal_info);
        }
    }
    if (builtin.related_ids.len > 0) {
        try out.appendSlice(allocator, "\n**Related:** ");
        for (builtin.related_ids, 0..) |related, index| {
            if (index > 0) try out.appendSlice(allocator, ", ");
            try appendFmt(allocator, out, "`{s}`", .{related});
        }
        try out.appendSlice(allocator, "\n");
    }
    try out.appendSlice(allocator, "\n---\n\n");
}

fn appendExportLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), export_info: *const catalog_show.MergedExport) ExportError!void {
    try appendFmt(allocator, out, "- `{s}`", .{export_info.name});
    if (export_info.type_hint.len > 0) {
        try appendFmt(allocator, out, " (`{s}`", .{export_info.type_hint});
        if (export_info.default_value.len > 0) {
            try appendFmt(allocator, out, ", default `{s}`", .{export_info.default_value});
        }
        try out.appendSlice(allocator, ")");
    } else if (export_info.default_value.len > 0) {
        try appendFmt(allocator, out, " (default `{s}`)", .{export_info.default_value});
    }
    if (export_info.group.len > 0) {
        try appendFmt(allocator, out, " — group `{s}`", .{export_info.group});
    }
    try out.appendSlice(allocator, "\n");
}

fn appendSignalLine(allocator: std.mem.Allocator, out: *std.ArrayList(u8), signal_info: *const catalog_show.MergedSignal) ExportError!void {
    try appendFmt(allocator, out, "- `{s}`", .{signal_info.name});
    if (signal_info.args.len > 0) {
        try appendFmt(allocator, out, "({s})", .{signal_info.args});
    }
    if (signal_info.doc.len > 0) {
        try appendFmt(allocator, out, " — {s}", .{signal_info.doc});
    }
    try out.appendSlice(allocator, "\n");
    if (signal_info.connect_example.len > 0) {
        try appendFmt(allocator, out, "  - Connect: `{s}`\n", .{signal_info.connect_example});
    }
}

test "render export markdown for fixture project" {
    const allocator = std.testing.allocator;
    var shown = try catalog_show.showById(allocator, std.testing.io, "test_fixtures/project", null, "ui/button");
    defer shown.deinit(allocator);

    const builtin = try catalog_builtins.findById(allocator, "godot/ui/Button") orelse return error.InvalidBuiltinCatalog;
    var builtin_shown = try showBuiltinForExport(allocator, builtin);
    defer builtin_shown.deinit(allocator);

    const markdown = try renderMarkdown(allocator, &.{shown}, &.{builtin_shown});
    defer allocator.free(markdown);

    try std.testing.expect(std.mem.indexOf(u8, markdown, "### `ui/button`") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "label_text") != null);
    try std.testing.expect(std.mem.indexOf(u8, markdown, "### `godot/ui/Button`") != null);
}

test "export catalog writes markdown file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const output_path = "test_fixtures/project/.catalog_export_test.md";
    defer std.Io.Dir.cwd().deleteFile(io, output_path) catch {};

    var result = try exportCatalog(
        allocator,
        io,
        "test_fixtures/project",
        null,
        output_path,
        false,
    );
    defer result.deinit(allocator);

    try std.testing.expect(result.wrote_file);
    try std.testing.expect(result.project_entry_count >= 1);
    try std.testing.expect(result.builtin_entry_count >= 1);
    const written = try std.Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .unlimited);
    defer allocator.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, "ui/button") != null);
}
