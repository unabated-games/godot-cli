//! `project export`: the presets in export_presets.cfg, and the export itself.
//!
//! The file format, the option tables and the checks live in
//! godot/export_presets.zig and godot/export_options.zig; this is the command
//! surface over them.

const std = @import("std");
const spec = @import("../cli/spec.zig");
const project = @import("project.zig");
const project_godot = @import("../godot/project_godot.zig");
const error_details = @import("../godot/error_details.zig");
const io_util = @import("../io_util.zig");
const godot_run = @import("../godot/godot_run.zig");
const export_options = @import("../godot/export_options.zig");
const export_presets = @import("../godot/export_presets.zig");
const editor_settings = @import("../godot/editor_settings.zig");
const types = export_options.types;
const app_mod = @import("../cli/app.zig");

const presets_file = "export_presets.cfg";
const credentials_file = ".godot/export_credentials.cfg";

const Loaded = struct {
    root: []const u8,
    presets_path: []const u8,
    credentials_path: []const u8,
    presets: export_presets.Presets,
    table: *const types.Table,
    /// The version project.godot names, or null when it names none.
    project_minor: ?[]const u8,
};

fn load(cli: *const app_mod.App, inv: *const spec.Invocation) !Loaded {
    const allocator = cli.allocator;
    const root = inv.getOption("project-root") orelse ".";
    const project_path = try std.fs.path.join(allocator, &.{ root, "project.godot" });
    var doc = project_godot.readFile(allocator, cli.io, project_path) catch {
        error_details.record(.{ .field = "project-root", .value = root, .hint = "no project.godot here; pass the folder that holds it" });
        return error.FileNotFound;
    };
    const features = if (doc.sectionMut("application")) |section| section.getEntry("config/features") else null;
    const minor = if (features) |text| export_options.minorFromFeatures(text) else null;
    const project_minor = if (minor) |m| try allocator.dupe(u8, m) else null;
    doc.deinit(allocator);

    const presets_path = try std.fs.path.join(allocator, &.{ root, presets_file });
    const credentials_path = try std.fs.path.join(allocator, &.{ root, credentials_file });
    const presets_text = std.Io.Dir.cwd().readFileAlloc(cli.io, presets_path, allocator, .unlimited) catch null;
    const credentials_text = std.Io.Dir.cwd().readFileAlloc(cli.io, credentials_path, allocator, .unlimited) catch null;
    const presets = export_presets.load(allocator, presets_text, credentials_text) catch {
        error_details.record(.{ .field = "export_presets.cfg", .value = presets_path, .hint = "the file is not ConfigFile text Godot could read" });
        return error.InvalidFormat;
    };
    return .{
        .root = root,
        .presets_path = presets_path,
        .credentials_path = credentials_path,
        .presets = presets,
        .table = export_options.forMinor(project_minor),
        .project_minor = project_minor,
    };
}

fn putTable(allocator: std.mem.Allocator, data: *std.json.ObjectMap, loaded: *const Loaded) !void {
    try data.put(allocator, "godot_version", .{ .string = loaded.table.minor });
    try data.put(allocator, "project_godot_version", if (loaded.project_minor) |m| .{ .string = m } else .null);
}

/// Godot text as the JSON an agent would have given: a bool, a number, a
/// string, or the Godot text itself for anything else.
fn jsonOf(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    if (std.mem.eql(u8, text, "true")) return .{ .bool = true };
    if (std.mem.eql(u8, text, "false")) return .{ .bool = false };
    if (std.fmt.parseInt(i64, text, 10)) |v| return .{ .integer = v } else |_| {}
    if (text.len > 0 and (std.ascii.isDigit(text[0]) or text[0] == '-')) {
        if (std.fmt.parseFloat(f64, text)) |v| return .{ .float = v } else |_| {}
    }
    if (text.len >= 2 and text[0] == '"') return .{ .string = export_presets.unquote(allocator, text) };
    if (std.mem.startsWith(u8, text, "PackedStringArray(")) {
        var items = std.json.Array.init(allocator);
        for (try export_presets.packedStrings(allocator, text)) |item| try items.append(.{ .string = item });
        return .{ .array = items };
    }
    return .{ .string = text };
}

const secret_placeholder = "(set; secrets are not shown)";

/// One preset for list and show: its keys, and the options that differ from
/// the default (all of them with `all_options`).
fn presetJson(allocator: std.mem.Allocator, loaded: *const Loaded, index: usize, all_options: bool) !std.json.Value {
    const preset = &loaded.presets.presets.items[index];
    const platform = export_options.findPlatform(loaded.table, preset.platform);
    var object: std.json.ObjectMap = .{};
    try object.put(allocator, "index", .{ .integer = @intCast(index) });
    try object.put(allocator, "name", .{ .string = preset.name });
    try object.put(allocator, "platform", .{ .string = preset.platform });
    try object.put(allocator, "known_platform", .{ .bool = platform != null });
    // Shown, not hidden: these are the presets someone is about to fix.
    if (platform == null) {
        const meant = export_options.resolvePlatform(loaded.table, preset.platform);
        try object.put(allocator, "godot_skips", .{ .string = if (meant) |m|
            try allocator.print("platform \"{s}\" is not a name Godot matches; it means \"{s}\". Correct it with project export apply and {{\"name\": \"{s}\", \"platform\": \"{s}\"}}", .{ preset.platform, m.name, preset.name, m.name })
        else
            try allocator.print("platform \"{s}\" is not one Godot exports to", .{preset.platform}) });
    } else if (preset.after_gap) {
        try object.put(allocator, "godot_skips", .{ .string = "after a gap in the preset numbering, where Godot stops reading; any project export apply renumbers it" });
    }
    try object.put(allocator, "runnable", .{ .bool = loaded.presets.isRunnable(preset) });
    for (loaded.table.preset_keys) |key| {
        if (std.mem.eql(u8, key.name, "name") or std.mem.eql(u8, key.name, "platform")) continue;
        try object.put(allocator, key.name, try jsonOf(allocator, preset.mainValue(key.name) orelse key.default));
    }
    if (preset.mainValue("export_files")) |files| try object.put(allocator, "export_files", try jsonOf(allocator, files));
    if (preset.mainValue("customized_files")) |files| try object.put(allocator, "customized_files", .{ .string = files });
    const key_set = for (preset.credential_main.items) |entry| {
        if (std.mem.eql(u8, entry.key, "script_encryption_key") and export_presets.unquote(allocator, entry.value).len > 0) break true;
    } else false;
    try object.put(allocator, "script_encryption_key_set", .{ .bool = key_set });

    var options: std.json.ObjectMap = .{};
    var changed: usize = 0;
    // Every option means every option the platform has, at its default
    // where the file sets nothing, as the editor would write it.
    if (all_options) if (platform) |p| for (p.options) |o| {
        if (preset.option(o.name) != null) continue;
        try options.put(allocator, o.name, try jsonOf(allocator, o.default));
    };
    for (preset.options.items) |entry| {
        const option = if (platform) |p| export_options.findOption(p, entry.key) else null;
        const is_default = if (option) |o| std.mem.eql(u8, o.default, entry.value) else false;
        if (!is_default) changed += 1;
        if (!all_options and is_default) continue;
        const secret = if (option) |o| o.secret else false;
        const shown: std.json.Value = if (secret and export_presets.unquote(allocator, entry.value).len > 0) .{ .string = secret_placeholder } else try jsonOf(allocator, entry.value);
        try options.put(allocator, entry.key, shown);
    }
    try object.put(allocator, "changed_option_count", .{ .integer = @intCast(changed) });
    try object.put(allocator, if (all_options) "options" else "changed_options", .{ .object = options });
    if (preset.line > 0) try object.put(allocator, "line", .{ .integer = @intCast(preset.line) });
    return .{ .object = object };
}

fn listHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = project.appFrom(ctx);
    const allocator = cli.allocator;
    const loaded = try load(cli, inv);
    var presets = std.json.Array.init(allocator);
    for (loaded.presets.presets.items, 0..) |_, index| try presets.append(try presetJson(allocator, &loaded, index, false));

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "path", .{ .string = loaded.presets_path });
    try data.put(allocator, "exists", .{ .bool = loaded.presets.exists });
    try data.put(allocator, "presets", .{ .array = presets });
    try putTable(allocator, &data, &loaded);
    const summary = if (!loaded.presets.exists)
        "no export_presets.cfg yet; project export apply creates one"
    else
        try allocator.print("{d} export preset(s)", .{loaded.presets.presets.items.len});
    try data.put(allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn findPreset(allocator: std.mem.Allocator, loaded: *const Loaded, name: []const u8) !usize {
    if (loaded.presets.find(name)) |index| return index;
    var names: std.ArrayList(u8) = .empty;
    for (loaded.presets.presets.items, 0..) |preset, i| {
        if (i > 0) try names.appendSlice(allocator, ", ");
        try names.appendSlice(allocator, preset.name);
    }
    error_details.record(.{
        .field = "preset",
        .value = name,
        .hint = if (names.items.len == 0) "there are no presets yet; project export apply creates one" else try allocator.print("presets: {s}", .{names.items}),
    });
    return error.ExportPresetNotFound;
}

fn showHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = project.appFrom(ctx);
    const allocator = cli.allocator;
    const loaded = try load(cli, inv);
    const name = inv.getOption("preset") orelse return error.Usage;
    const index = try findPreset(allocator, &loaded, name);
    var data = (try presetJson(allocator, &loaded, index, inv.flag("all-options"))).object;
    try data.put(allocator, "path", .{ .string = loaded.presets_path });
    try putTable(allocator, &data, &loaded);
    const preset = loaded.presets.presets.items[index];
    try data.put(allocator, "summary", .{ .string = try allocator.print("{s}: a {s} preset", .{ preset.name, preset.platform }) });
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn optionsHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = project.appFrom(ctx);
    const allocator = cli.allocator;
    const loaded = try load(cli, inv);
    const given = inv.getOption("platform") orelse return error.Usage;
    const platform = export_options.resolvePlatform(loaded.table, given) orelse {
        var names: std.ArrayList(u8) = .empty;
        for (loaded.table.platforms, 0..) |p, i| {
            if (i > 0) try names.appendSlice(allocator, ", ");
            try names.appendSlice(allocator, p.name);
        }
        error_details.record(.{ .field = "platform", .value = given, .hint = try allocator.print("one of: {s}", .{names.items}) });
        return error.ExportUnknownPlatform;
    };
    const filter = inv.getOption("filter");

    var options = std.json.Array.init(allocator);
    for (platform.options) |option| {
        if (filter) |f| if (std.ascii.findIgnoreCase(option.name, f) == null) continue;
        var object: std.json.ObjectMap = .{};
        try object.put(allocator, "name", .{ .string = option.name });
        try object.put(allocator, "default", try jsonOf(allocator, option.default));
        try object.put(allocator, "type", .{ .string = @tagName(option.kind) });
        if (option.choices.len > 0) {
            var choices = std.json.Array.init(allocator);
            for (option.choices) |choice| try choices.append(.{ .string = choice.label });
            try object.put(allocator, "choices", .{ .array = choices });
        }
        if (option.secret) try object.put(allocator, "secret", .{ .bool = true });
        try options.append(.{ .object = object });
    }
    var keys = std.json.Array.init(allocator);
    for (loaded.table.preset_keys) |key| {
        if (std.mem.eql(u8, key.name, "name") or std.mem.eql(u8, key.name, "platform")) continue;
        if (filter) |f| if (std.ascii.findIgnoreCase(key.name, f) == null) continue;
        var object: std.json.ObjectMap = .{};
        try object.put(allocator, "name", .{ .string = key.name });
        try object.put(allocator, "default", try jsonOf(allocator, key.default));
        try keys.append(.{ .object = object });
    }

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "platform", .{ .string = platform.name });
    try data.put(allocator, "options", .{ .array = options });
    try data.put(allocator, "preset_keys", .{ .array = keys });
    try putTable(allocator, &data, &loaded);
    try data.put(allocator, "summary", .{ .string = try allocator.print("{d} {s} option(s) in Godot {s}", .{ options.items.len, platform.name, loaded.table.minor }) });
    return .{ .data = .{ .object = data }, .messages = &.{} };
}

fn refusalError(refusal: export_presets.Refusal) anyerror {
    const kinds = [_]struct { kind: []const u8, err: anyerror }{
        .{ .kind = "unknown_platform", .err = error.ExportUnknownPlatform },
        .{ .kind = "unknown_option", .err = error.ExportUnknownOption },
        .{ .kind = "invalid_value", .err = error.ExportInvalidValue },
        .{ .kind = "preset_not_found", .err = error.ExportPresetNotFound },
        .{ .kind = "unknown_field", .err = error.ExportUnknownField },
        .{ .kind = "duplicate_name", .err = error.ExportDuplicateName },
    };
    for (kinds) |entry| if (std.mem.eql(u8, entry.kind, refusal.kind)) return entry.err;
    return error.InvalidIntent;
}

fn stringArray(allocator: std.mem.Allocator, items: []const []const u8) !std.json.Value {
    var array = std.json.Array.init(allocator);
    for (items) |item| try array.append(.{ .string = item });
    return .{ .array = array };
}

fn applyHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = project.appFrom(ctx);
    const allocator = cli.allocator;
    var loaded = try load(cli, inv);
    const source = try project.readIntentSource(cli, inv);
    const intent = std.json.parseFromSliceLeaky(std.json.Value, allocator, source.bytes, .{}) catch {
        error_details.record(.{ .field = "intent", .value = source.label, .hint = "not valid JSON" });
        return error.InvalidIntent;
    };
    var refusal: export_presets.Refusal = .{};
    var applied = export_presets.apply(allocator, &loaded.presets, loaded.table, intent, &refusal) catch |err| switch (err) {
        error.InvalidIntent => {
            error_details.record(.{
                .field = if (refusal.field.len > 0) refusal.field else null,
                .value = if (refusal.value.len > 0) refusal.value else null,
                .hint = if (refusal.hint.len > 0) refusal.hint else null,
            });
            return refusalError(refusal);
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    // Secrets the file held in the open leave it on this write, as they would
    // on the editor's next save.
    var moved: std.ArrayList([]const u8) = .empty;
    for (loaded.presets.presets.items) |preset| {
        const platform = export_options.findPlatform(loaded.table, preset.platform) orelse continue;
        for (preset.options.items) |entry| {
            if (!preset.options_in_presets_file.contains(entry.key)) continue;
            const option = export_options.findOption(platform, entry.key) orelse continue;
            if (option.secret and export_presets.unquote(allocator, entry.value).len > 0) {
                try moved.append(allocator, try allocator.print("{s}: {s}", .{ preset.name, entry.key }));
            }
        }
    }
    if (moved.items.len > 0) {
        try applied.messages.append(allocator, try allocator.print("{d} secret(s) were in export_presets.cfg and move to .godot/export_credentials.cfg, values unchanged; if the presets file was ever pushed, change them", .{moved.items.len}));
    }
    if (loaded.project_minor == null) {
        try applied.messages.append(allocator, try allocator.print("project.godot names no Godot version (config/features), so the presets carry Godot {s}'s options; an older editor keeps the ones it does not know", .{loaded.table.minor}));
    }
    if (applied.secrets.items.len > 0 or moved.items.len > 0) {
        try applied.messages.append(allocator, "secrets went to .godot/export_credentials.cfg, as the editor keeps them: that file is not committed, so set them again on another machine or in CI");
        if (!try gitignoresGodotDir(cli, loaded.root)) {
            try applied.messages.append(allocator, "no .gitignore here ignores .godot/, so a git add of the whole project would commit those secrets. Godot's own project manager writes a .gitignore holding .godot/");
        }
    }

    const rendered = try export_presets.render(allocator, &loaded.presets, loaded.table);
    const dry_run = inv.flag("dry-run");
    var gdignores: std.ArrayList([]const u8) = .empty;
    if (!dry_run) {
        io_util.writeFileAtomic(cli.io, loaded.presets_path, rendered.presets) catch return error.Io;
        if (std.fs.path.dirname(loaded.credentials_path)) |dir| std.Io.Dir.cwd().createDirPath(cli.io, dir) catch {};
        io_util.writeFileAtomic(cli.io, loaded.credentials_path, rendered.credentials) catch return error.Io;
    }
    // An export folder inside the project gets the .gdignore build would add,
    // so the presets validate clean as soon as they are written. A dry run
    // reports the ones it would add.
    for (loaded.presets.presets.items) |preset| {
        const path = export_presets.unquote(allocator, preset.mainValue("export_path") orelse "\"\"");
        if (path.len == 0 or std.fs.path.isAbsolute(path)) continue;
        if (try ensureGdignore(cli, loaded.root, path, dry_run)) |folder| {
            for (gdignores.items) |seen| {
                if (std.mem.eql(u8, seen, folder)) break;
            } else try gdignores.append(allocator, folder);
        }
    }

    var names = std.json.Array.init(allocator);
    for (loaded.presets.presets.items) |preset| try names.append(.{ .string = preset.name });
    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "path", .{ .string = loaded.presets_path });
    try data.put(allocator, "credentials_path", .{ .string = loaded.credentials_path });
    try data.put(allocator, "intent", .{ .string = source.label });
    try data.put(allocator, "created", try stringArray(allocator, applied.created.items));
    try data.put(allocator, "updated", try stringArray(allocator, applied.updated.items));
    try data.put(allocator, "removed", try stringArray(allocator, applied.removed.items));
    // Each updated preset's changed values, old to new, so a repair can be
    // checked without reading the files: anything not listed was kept.
    var changes: std.json.ObjectMap = .{};
    for (applied.updated.items) |name| {
        if (changes.get(name) == null) try changes.put(allocator, name, .{ .array = std.json.Array.init(allocator) });
    }
    for (applied.changes.items) |change| {
        const entry = try changes.getOrPut(allocator, change.preset);
        if (!entry.found_existing) entry.value_ptr.* = .{ .array = std.json.Array.init(allocator) };
        var object: std.json.ObjectMap = .{};
        try object.put(allocator, "key", .{ .string = change.key });
        if (change.secret) {
            try object.put(allocator, "secret", .{ .bool = true });
        } else {
            try object.put(allocator, "old", if (change.old) |text| try jsonOf(allocator, text) else .null);
            try object.put(allocator, "new", if (change.new) |text| try jsonOf(allocator, text) else .null);
        }
        try entry.value_ptr.array.append(.{ .object = object });
    }
    try data.put(allocator, "changes", .{ .object = changes });
    try data.put(allocator, "secrets_written", try stringArray(allocator, applied.secrets.items));
    try data.put(allocator, "secrets_moved", try stringArray(allocator, moved.items));
    try data.put(allocator, "gdignore_created", try stringArray(allocator, gdignores.items));
    for (gdignores.items) |folder| {
        try applied.messages.append(allocator, try allocator.print("{s} {s}/.gdignore: builds go there, and without it Godot imports them as project files and packs one build into the next", .{ if (dry_run) "would add" else "added", folder }));
    }
    try data.put(allocator, "presets", .{ .array = names });
    try putTable(allocator, &data, &loaded);
    try data.put(allocator, "dry_run", .{ .bool = dry_run });
    const summary = try allocator.print("{d} created, {d} updated ({d} value(s) changed), {d} removed; {d} preset(s) in {s}", .{
        applied.created.items.len, applied.updated.items.len, applied.changes.items.len, applied.removed.items.len, loaded.presets.presets.items.len, presets_file,
    });
    try data.put(allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .messages = applied.messages.items };
}

/// Whether the project's .gitignore has a line ignoring .godot/.
pub fn gitignoresGodotDir(cli: *const app_mod.App, root: []const u8) !bool {
    const path = try std.fs.path.join(cli.allocator, &.{ root, ".gitignore" });
    const text = std.Io.Dir.cwd().readFileAlloc(cli.io, path, cli.allocator, .unlimited) catch return false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        const bare = std.mem.trim(u8, trimmed, "/");
        if (std.mem.eql(u8, bare, ".godot") or std.mem.eql(u8, bare, ".godot/*")) return true;
    }
    return false;
}

const ResCheck = struct {
    cli: *const app_mod.App,
    root: []const u8,

    /// `res://` and relative paths are the project's; absolute ones are
    /// this machine's.
    fn exists(ctx: *anyopaque, given: []const u8) bool {
        const self: *const ResCheck = @ptrCast(@alignCast(ctx));
        const path = if (std.mem.startsWith(u8, given, "res://"))
            std.fs.path.join(self.cli.allocator, &.{ self.root, given["res://".len..] }) catch return true
        else if (std.fs.path.isAbsolute(given))
            given
        else
            std.fs.path.join(self.cli.allocator, &.{ self.root, given }) catch return true;
        std.Io.Dir.cwd().access(self.cli.io, path, .{}) catch return false;
        return true;
    }
};

fn validateHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = project.appFrom(ctx);
    const allocator = cli.allocator;
    var loaded = try load(cli, inv);
    var check: ResCheck = .{ .cli = cli, .root = loaded.root };
    const issues = try export_presets.validate(allocator, &loaded.presets, loaded.table, ResCheck.exists, @ptrCast(&check));

    var list = std.json.Array.init(allocator);
    var errors: usize = 0;
    for (issues) |issue| {
        if (issue.severity == .@"error") errors += 1;
        var object: std.json.ObjectMap = .{};
        try object.put(allocator, "severity", .{ .string = @tagName(issue.severity) });
        try object.put(allocator, "kind", .{ .string = issue.kind });
        if (issue.preset) |p| try object.put(allocator, "preset", .{ .string = p });
        try object.put(allocator, "message", .{ .string = issue.message });
        if (issue.line > 0) try object.put(allocator, "line", .{ .integer = @intCast(issue.line) });
        try object.put(allocator, "file", .{ .string = issue.file orelse presets_file });
        try list.append(.{ .object = object });
    }

    errors += try androidReadiness(cli, &loaded, &list);
    if (loaded.presets.presets.items.len > 0) try templateReadiness(cli, &list);

    // Would the editor's next save rewrite the file? A preset with only some
    // of its options is valid and exports, but opening the project fills the
    // rest in: a diff nobody asked for.
    var written_by_editor = true;
    if (loaded.presets.exists) {
        const rendered = try export_presets.render(allocator, &loaded.presets, loaded.table);
        const current = std.Io.Dir.cwd().readFileAlloc(cli.io, loaded.presets_path, allocator, .unlimited) catch "";
        written_by_editor = std.mem.eql(u8, rendered.presets, current);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "path", .{ .string = loaded.presets_path });
    try data.put(allocator, "exists", .{ .bool = loaded.presets.exists });
    try data.put(allocator, "issues", .{ .array = list });
    try data.put(allocator, "error_count", .{ .integer = @intCast(errors) });
    try data.put(allocator, "warning_count", .{ .integer = @intCast(list.items.len - errors) });
    try data.put(allocator, "matches_editor_save", .{ .bool = written_by_editor });
    try putTable(allocator, &data, &loaded);
    const summary = try allocator.print("{s}: {d} preset(s), {d} issue(s), {d} error(s){s}", .{
        presets_file,
        loaded.presets.presets.items.len,
        list.items.len,
        errors,
        if (written_by_editor) "" else "; the editor would rewrite it on its next save. project export apply with an empty intent writes that now and keeps every preset, renumbering any past a gap; a platform Godot does not match needs correcting in the intent",
    });
    try data.put(allocator, "summary", .{ .string = summary });
    return .{ .data = .{ .object = data }, .messages = &.{}, .exit_code = if (errors == 0) .success else .failure };
}

fn addIssue(allocator: std.mem.Allocator, list: *std.json.Array, kind: []const u8, preset: ?[]const u8, message: []const u8, file: []const u8) !void {
    var object: std.json.ObjectMap = .{};
    try object.put(allocator, "severity", .{ .string = "warning" });
    try object.put(allocator, "kind", .{ .string = kind });
    if (preset) |p| try object.put(allocator, "preset", .{ .string = p });
    try object.put(allocator, "message", .{ .string = message });
    try object.put(allocator, "file", .{ .string = file });
    try list.append(.{ .object = object });
}

fn fileExists(cli: *const app_mod.App, path: []const u8) bool {
    return if (std.Io.Dir.cwd().access(cli.io, path, .{})) |_| true else |_| false;
}

/// What Godot refuses an Android export for that lives on this machine, not
/// in the project: the Java and Android SDK paths in the editor settings,
/// adb and apksigner under the SDK, the debug keystore, and a release
/// keystore given in part (`has_valid_export_configuration` in Godot's
/// Android exporter). Trial 39 met these only after a full Godot run.
/// Warnings, since the release may well be built on another machine.
/// Returns the number of errors added: none.
fn androidReadiness(cli: *const app_mod.App, loaded: *const Loaded, list: *std.json.Array) !usize {
    const allocator = cli.allocator;
    var first_android: ?[]const u8 = null;
    for (loaded.presets.presets.items) |preset| {
        if (std.mem.eql(u8, preset.platform, "Android") and !preset.after_gap) {
            first_android = preset.name;
            break;
        }
    }
    const android_preset = first_android orelse return 0;

    const exe = if (@import("builtin").os.tag == .windows) ".exe" else "";
    const settings_path = editor_settings.findFile(allocator, cli.io, cli.environ, loaded.project_minor);
    const settings_text: []const u8 = if (settings_path) |path|
        std.Io.Dir.cwd().readFileAlloc(cli.io, path, allocator, .unlimited) catch ""
    else
        "";
    if (settings_path == null) {
        try addIssue(allocator, list, "android_editor_settings_missing", android_preset, try allocator.print("no Godot editor settings were found in {s}, so the Java and Android SDK paths an Android export needs could not be checked; open the editor once and set them under Editor Settings > Export > Android", .{editor_settings.configDir(allocator, cli.environ) orelse "the editor's config folder"}), "editor settings");
    } else {
        const file = settings_path.?;
        const java = editor_settings.stringValue(allocator, settings_text, "export/android/java_sdk_path") orelse "";
        if (java.len == 0) {
            try addIssue(allocator, list, "android_java_sdk", android_preset, "export/android/java_sdk_path is not set in the editor settings, and Godot refuses an Android export without it: set it to a JDK 17 folder (the one holding bin/java) under Editor Settings > Export > Android", file);
        } else if (!fileExists(cli, try std.fs.path.join(allocator, &.{ java, "bin", try allocator.print("java{s}", .{exe}) }))) {
            try addIssue(allocator, list, "android_java_sdk", android_preset, try allocator.print("export/android/java_sdk_path is {s}, which has no bin/java, so Godot refuses an Android export; point it at a JDK 17 folder", .{java}), file);
        }
        const sdk = editor_settings.stringValue(allocator, settings_text, "export/android/android_sdk_path") orelse "";
        if (sdk.len == 0) {
            try addIssue(allocator, list, "android_sdk", android_preset, "export/android/android_sdk_path is not set in the editor settings, and Godot refuses an Android export without it: set it to the Android SDK folder (the one holding platform-tools) under Editor Settings > Export > Android", file);
        } else if (!fileExists(cli, try std.fs.path.join(allocator, &.{ sdk, "platform-tools", try allocator.print("adb{s}", .{exe}) }))) {
            try addIssue(allocator, list, "android_sdk", android_preset, try allocator.print("export/android/android_sdk_path is {s}, which has no platform-tools/adb, so Godot refuses an Android export; install platform-tools with the SDK manager or point the setting at a full SDK", .{sdk}), file);
        } else if (!hasApksigner(cli, sdk, exe)) {
            try addIssue(allocator, list, "android_sdk", android_preset, try allocator.print("the Android SDK at {s} has no build-tools/<version>/apksigner, so Godot cannot sign the export; install a build-tools package", .{sdk}), file);
        }
    }

    for (loaded.presets.presets.items) |preset| {
        if (!std.mem.eql(u8, preset.platform, "Android") or preset.after_gap) continue;
        const credentials = credentials_file;
        // A preset value, or the environment variable Godot reads in its place.
        const Value = struct {
            fn get(c: *const app_mod.App, p: export_presets.Preset, key: []const u8, env: []const u8) []const u8 {
                const text = export_presets.unquote(c.allocator, p.option(key) orelse "\"\"");
                if (text.len > 0) return text;
                return c.environ.getAlloc(c.allocator, env) catch "";
            }
        };
        const debug = Value.get(cli, preset, "keystore/debug", "GODOT_ANDROID_KEYSTORE_DEBUG_PATH");
        if (debug.len == 0) {
            const fallback = editor_settings.stringValue(allocator, settings_text, "export/android/debug_keystore") orelse "";
            if (settings_path != null and (fallback.len == 0 or !fileExists(cli, fallback))) {
                try addIssue(allocator, list, "android_debug_keystore", preset.name, if (fallback.len == 0)
                    "no debug keystore: the preset sets no keystore/debug and the editor settings no export/android/debug_keystore, so a debug export fails; opening the editor once creates one"
                else
                    try allocator.print("the editor's debug keystore {s} does not exist, and the preset sets no keystore/debug, so a debug export fails", .{fallback}), settings_path.?);
            }
        }
        const release = Value.get(cli, preset, "keystore/release", "GODOT_ANDROID_KEYSTORE_RELEASE_PATH");
        const release_user = Value.get(cli, preset, "keystore/release_user", "GODOT_ANDROID_KEYSTORE_RELEASE_USER");
        const release_password = Value.get(cli, preset, "keystore/release_password", "GODOT_ANDROID_KEYSTORE_RELEASE_PASSWORD");
        const set_count = @as(u8, @intFromBool(release.len > 0)) + @intFromBool(release_user.len > 0) + @intFromBool(release_password.len > 0);
        if (set_count > 0 and set_count < 3) {
            var missing: std.ArrayList([]const u8) = .empty;
            if (release.len == 0) try missing.append(allocator, "keystore/release");
            if (release_user.len == 0) try missing.append(allocator, "keystore/release_user");
            if (release_password.len == 0) try missing.append(allocator, "keystore/release_password");
            try addIssue(allocator, list, "android_release_keystore", preset.name, try allocator.print("a release keystore needs its path, user and password together, or none of them, and Godot refuses a release export otherwise; missing: {s} (the preset, or GODOT_ANDROID_KEYSTORE_RELEASE_PATH, _USER and _PASSWORD in the environment)", .{try std.mem.join(allocator, ", ", missing.items)}), credentials);
        }
    }
    return 0;
}

/// Export templates for the exact Godot on the path. Without them every
/// build fails as export_templates_missing; trial 43's validate passed and its
/// build then failed. Silent when there is no Godot to ask.
fn templateReadiness(cli: *const app_mod.App, list: *std.json.Array) !void {
    const allocator = cli.allocator;
    const godot = godot_run.locateGodot(allocator, cli.io, cli.environ, null) catch return;
    const outcome = godot_run.runProcess(allocator, cli.environ, ".", &.{ godot, "--version" }) catch return;
    const version = editor_settings.templatesVersion(outcome.stdout[0 .. std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len]) orelse return;
    const dir = editor_settings.templatesDir(allocator, cli.environ) orelse return;
    const folder = try std.fs.path.join(allocator, &.{ dir, version });
    if (fileExists(cli, folder)) return;
    try addIssue(allocator, list, "export_templates_missing", null, try allocator.print("no export templates for Godot {s} (the godot at {s}) in {s}, so project export build fails for every preset until they are installed: Editor > Manage Export Templates, or unpack the matching .tpz from the Godot release there", .{ version, godot, folder }), "export templates");
}

fn hasApksigner(cli: *const app_mod.App, sdk: []const u8, exe: []const u8) bool {
    const tools = std.fs.path.join(cli.allocator, &.{ sdk, "build-tools" }) catch return false;
    var dir = std.Io.Dir.cwd().openDir(cli.io, tools, .{ .iterate = true }) catch return false;
    defer dir.close(cli.io);
    var it = dir.iterate();
    const name = if (exe.len > 0) "apksigner.bat" else "apksigner";
    while (it.next(cli.io) catch null) |entry| {
        if (entry.kind != .directory) continue;
        const candidate = std.fs.path.join(cli.allocator, &.{ tools, entry.name, name }) catch continue;
        if (fileExists(cli, candidate)) return true;
    }
    return false;
}

/// `build` for `build/windows/game.exe`; null for a file at the root.
fn buildFolder(output: []const u8) ?[]const u8 {
    const relative = if (std.mem.startsWith(u8, output, "res://")) output["res://".len..] else output;
    if (std.mem.startsWith(u8, relative, "..")) return null;
    const slash = std.mem.indexOfAny(u8, relative, "/\\") orelse return null;
    if (slash == 0 or std.mem.eql(u8, relative[0..slash], ".")) return null;
    return relative[0..slash];
}

/// Write `<folder>/.gdignore` for an output path inside the project, if it
/// is not there yet; the folder when one was written.
fn ensureGdignore(cli: *const app_mod.App, root: []const u8, output: []const u8, dry_run: bool) !?[]const u8 {
    const folder = buildFolder(output) orelse return null;
    const marker = try std.fs.path.join(cli.allocator, &.{ root, folder, ".gdignore" });
    if (std.Io.Dir.cwd().access(cli.io, marker, .{})) |_| return null else |_| {}
    if (dry_run) return folder;
    std.Io.Dir.cwd().createDirPath(cli.io, try std.fs.path.join(cli.allocator, &.{ root, folder })) catch {};
    io_util.writeFileAtomic(cli.io, marker, "") catch return error.Io;
    return folder;
}

const BuildOne = struct {
    data: std.json.ObjectMap,
    messages: []const []const u8,
    ok: bool,
    failure_kind: ?[]const u8,
};

fn buildHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = project.appFrom(ctx);
    const allocator = cli.allocator;
    const loaded = try load(cli, inv);
    const mode = if (inv.flag("pack")) "--export-pack" else if (inv.flag("debug")) "--export-debug" else "--export-release";
    if (inv.flag("all")) return buildAll(cli, inv, &loaded, mode);
    const name = inv.getOption("preset") orelse {
        error_details.record(.{ .field = "preset", .hint = "name the preset to export, or pass all to export every preset" });
        return error.Usage;
    };
    const index = try findPreset(allocator, &loaded, name);
    const preset = loaded.presets.presets.items[index];
    if (export_options.findPlatform(loaded.table, preset.platform) == null) {
        error_details.record(.{ .field = "preset", .value = name, .hint = try allocator.print("its platform \"{s}\" is not one Godot knows, so Godot cannot find this preset; project export validate says more", .{preset.platform}) });
        return error.ExportUnknownPlatform;
    }

    const output = inv.getOption("output") orelse blk: {
        const path = export_presets.unquote(allocator, preset.mainValue("export_path") orelse "\"\"");
        if (path.len == 0) {
            error_details.record(.{ .field = "output", .hint = "the preset has no export_path; pass output, or set export_path with project export apply" });
            return error.Usage;
        }
        break :blk path;
    };
    const godot = try godot_run.locateGodot(allocator, cli.io, cli.environ, inv.getOption("godot"));
    const one = try buildOne(cli, &loaded, preset, output, mode, godot);
    return .{
        .data = .{ .object = one.data },
        .messages = one.messages,
        .exit_code = if (one.ok) .success else .failure,
        .failure_kind = one.failure_kind,
    };
}

/// Every preset in turn, carrying on past a failure, each reported as
/// a single build would be.
fn buildAll(cli: *const app_mod.App, inv: *const spec.Invocation, loaded: *const Loaded, mode: []const u8) !spec.Result {
    const allocator = cli.allocator;
    if (inv.getOption("preset") != null or inv.getOption("output") != null) {
        error_details.record(.{ .field = if (inv.getOption("preset") != null) "preset" else "output", .hint = "all exports every preset to its own export_path; drop preset and output, or drop all" });
        return error.Usage;
    }
    if (loaded.presets.presets.items.len == 0) {
        error_details.record(.{ .field = "all", .hint = "there are no presets yet; project export apply creates one" });
        return error.ExportPresetNotFound;
    }
    const godot = try godot_run.locateGodot(allocator, cli.io, cli.environ, inv.getOption("godot"));
    var results = std.json.Array.init(allocator);
    var messages: std.ArrayList([]const u8) = .empty;
    var built: std.ArrayList([]const u8) = .empty;
    var failed: std.ArrayList([]const u8) = .empty;
    var templates_missing = false;
    for (loaded.presets.presets.items) |preset| {
        const skip: ?[]const u8 = if (export_options.findPlatform(loaded.table, preset.platform) == null)
            try allocator.print("its platform \"{s}\" is not one Godot knows, so Godot cannot find this preset; project export validate says more", .{preset.platform})
        else if (preset.after_gap)
            "it is past a gap in the preset numbering, where Godot stops reading; any project export apply renumbers it"
        else if (export_presets.unquote(allocator, preset.mainValue("export_path") orelse "\"\"").len == 0)
            "it has no export_path; set one with project export apply"
        else
            null;
        if (skip) |reason| {
            var data: std.json.ObjectMap = .{};
            try data.put(allocator, "preset", .{ .string = preset.name });
            try data.put(allocator, "platform", .{ .string = preset.platform });
            try data.put(allocator, "ok", .{ .bool = false });
            try data.put(allocator, "skipped", .{ .string = reason });
            try data.put(allocator, "summary", .{ .string = try allocator.print("skipped {s}: {s}", .{ preset.name, reason }) });
            try results.append(.{ .object = data });
            try failed.append(allocator, preset.name);
            continue;
        }
        const output = export_presets.unquote(allocator, preset.mainValue("export_path").?);
        var one = try buildOne(cli, loaded, preset, output, mode, godot);
        try one.data.put(allocator, "ok", .{ .bool = one.ok });
        if (one.failure_kind) |kind| {
            try one.data.put(allocator, "failure_kind", .{ .string = kind });
            if (std.mem.eql(u8, kind, "export_templates_missing")) templates_missing = true;
        }
        for (one.messages) |message| {
            try messages.append(allocator, try allocator.print("{s}: {s}", .{ preset.name, message }));
        }
        try results.append(.{ .object = one.data });
        try (if (one.ok) &built else &failed).append(allocator, preset.name);
    }

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "mode", .{ .string = mode[2..] });
    try data.put(allocator, "godot", .{ .string = godot });
    try data.put(allocator, "results", .{ .array = results });
    try data.put(allocator, "built", try stringArray(allocator, built.items));
    try data.put(allocator, "failed", try stringArray(allocator, failed.items));
    const summary = if (failed.items.len == 0)
        try allocator.print("exported all {d} preset(s)", .{built.items.len})
    else
        try allocator.print("exported {d} of {d} preset(s); not exported: {s}. Each result's summary says why", .{ built.items.len, built.items.len + failed.items.len, try std.mem.join(allocator, ", ", failed.items) });
    try data.put(allocator, "summary", .{ .string = summary });
    const ok = failed.items.len == 0;
    return .{
        .data = .{ .object = data },
        .messages = messages.items,
        .exit_code = if (ok) .success else .failure,
        .failure_kind = if (ok) null else if (templates_missing and built.items.len == 0) "export_templates_missing" else "export_failed",
    };
}

/// Export one preset to `output` with Godot.
fn buildOne(
    cli: *const app_mod.App,
    loaded: *const Loaded,
    preset: export_presets.Preset,
    output: []const u8,
    mode: []const u8,
    godot: []const u8,
) !BuildOne {
    const allocator = cli.allocator;
    const name = preset.name;
    // Godot resolves a relative output path against the project folder.
    const output_fs = if (std.fs.path.isAbsolute(output)) output else try std.fs.path.join(allocator, &.{ loaded.root, output });
    if (std.fs.path.dirname(output_fs)) |dir| std.Io.Dir.cwd().createDirPath(cli.io, dir) catch {};
    std.Io.Dir.cwd().deleteFile(cli.io, output_fs) catch {};

    // Godot imports whatever is in the project when it scans, export folders
    // included, and an all_resources export then packs the last build into
    // this one. A .gdignore in the folder is Godot's way to say "not ours";
    // trial 38 found a web build's icons imported by the next export.
    var messages: std.ArrayList([]const u8) = .empty;
    var gdignore: ?[]const u8 = null;
    if (!std.fs.path.isAbsolute(output)) {
        if (buildFolder(output) == null) {
            try messages.append(allocator, "the output is in the project root, where Godot imports it and the next export packs it; give it a folder such as build/");
        } else if (try ensureGdignore(cli, loaded.root, output, false)) |folder| {
            gdignore = try std.fs.path.join(allocator, &.{ folder, ".gdignore" });
            try messages.append(allocator, try allocator.print("added {s}/.gdignore so Godot does not import builds as project files, or pack one build into the next", .{folder}));
        }
    }

    const outcome = try godot_run.runProcess(allocator, cli.environ, loaded.root, &.{ godot, "--headless", "--path", ".", mode, name, output });
    const code: ?u8 = switch (outcome.term) {
        .exited => |c| c,
        else => null,
    };
    const written = if (std.Io.Dir.cwd().access(cli.io, output_fs, .{})) |_| true else |_| false;
    const ok = code != null and code.? == 0 and written;

    // Godot names the template it looked for; that is the fix, so it is the
    // thing to report.
    const log = try std.mem.concat(allocator, u8, &.{ outcome.stdout, "\n", outcome.stderr });
    const marker = "No export template found at the expected path:";
    const missing_template: ?[]const u8 = if (std.mem.indexOf(u8, log, marker)) |at| blk: {
        const rest = std.mem.trimStart(u8, log[at + marker.len ..], " \r\n");
        const end = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        break :blk std.mem.trim(u8, rest[0..end], " \r");
    } else null;

    // An ERROR line is often only a header ("due to configuration errors:"),
    // with the reasons on the lines after it, unprefixed, up to the "at:"
    // line. Those reasons are the useful part.
    var errors = std.json.Array.init(allocator);
    var reasons: std.ArrayList([]const u8) = .empty;
    var in_error = false;
    var lines = std.mem.splitScalar(u8, log, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r\t");
        if (std.mem.startsWith(u8, trimmed, "ERROR:")) {
            in_error = true;
            if (errors.items.len < 24) try errors.append(.{ .string = trimmed });
        } else if (in_error) {
            if (trimmed.len == 0 or std.mem.startsWith(u8, trimmed, "at:")) {
                in_error = false;
            } else if (errors.items.len < 24) {
                try errors.append(.{ .string = trimmed });
                try reasons.append(allocator, trimmed);
            }
        }
    }

    var files = std.json.Array.init(allocator);
    if (written) {
        const dir_path = std.fs.path.dirname(output_fs) orelse ".";
        const base = std.fs.path.basename(output_fs);
        const stem = if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| base[0..dot] else base;
        if (std.Io.Dir.cwd().openDir(cli.io, dir_path, .{ .iterate = true })) |dir_handle| {
            var dir = dir_handle;
            defer dir.close(cli.io);
            var it = dir.iterate();
            while (it.next(cli.io) catch null) |entry| {
                if (entry.kind != .file or !std.mem.startsWith(u8, entry.name, stem)) continue;
                const stat = dir.statFile(cli.io, entry.name, .{}) catch continue;
                var object: std.json.ObjectMap = .{};
                try object.put(allocator, "path", .{ .string = try std.fs.path.join(allocator, &.{ dir_path, entry.name }) });
                try object.put(allocator, "bytes", .{ .integer = @intCast(stat.size) });
                try files.append(.{ .object = object });
            }
        } else |_| {}
    }

    var data: std.json.ObjectMap = .{};
    try data.put(allocator, "preset", .{ .string = name });
    try data.put(allocator, "platform", .{ .string = preset.platform });
    try data.put(allocator, "mode", .{ .string = mode[2..] });
    try data.put(allocator, "output", .{ .string = output });
    try data.put(allocator, "output_path", .{ .string = output_fs });
    try data.put(allocator, "godot", .{ .string = godot });
    if (code) |c| try data.put(allocator, "exit", .{ .integer = c });
    try data.put(allocator, "files", .{ .array = files });
    try data.put(allocator, "errors", .{ .array = errors });
    if (missing_template) |path| try data.put(allocator, "missing_template", .{ .string = path });
    if (gdignore) |path| try data.put(allocator, "gdignore_created", .{ .string = path });
    if (!ok) {
        try data.put(allocator, "stdout_tail", .{ .string = project.tail(outcome.stdout, 1500) });
        try data.put(allocator, "stderr_tail", .{ .string = project.tail(outcome.stderr, 1500) });
    }
    const summary = if (ok)
        try allocator.print("exported {s} to {s}", .{ name, output })
    else if (missing_template) |path|
        try allocator.print("no export templates for this Godot: it looked for {s}. Install them from the editor (Editor > Manage Export Templates) or unpack the matching .tpz from the Godot release into that folder", .{path})
    else if (reasons.items.len > 0)
        try allocator.print("Godot did not export {s}: {s}", .{ name, try std.mem.join(allocator, " ", reasons.items) })
    else if (errors.items.len > 0)
        try allocator.print("Godot did not export {s}: {s}", .{ name, if (std.mem.startsWith(u8, errors.items[0].string, "ERROR: ")) errors.items[0].string["ERROR: ".len..] else errors.items[0].string })
    else
        try allocator.print("Godot did not export {s}; see errors and stderr_tail", .{name});
    try data.put(allocator, "summary", .{ .string = summary });
    return .{
        .data = data,
        .messages = messages.items,
        .ok = ok,
        .failure_kind = if (ok) null else if (missing_template != null) "export_templates_missing" else "export_failed",
    };
}

const root_option = spec.OptionSpec{ .long = "project-root", .kind = .path, .description = "Godot project root (default: current directory)" };
const list_options = [_]spec.OptionSpec{root_option};
const show_options = [_]spec.OptionSpec{
    root_option,
    .{ .long = "preset", .kind = .string, .required = true, .description = "The preset's name, as project export list shows it" },
    .{ .long = "all-options", .kind = .flag, .description = "Every option with its value, not only the ones that differ from the default" },
};
const options_options = [_]spec.OptionSpec{
    root_option,
    .{ .long = "platform", .kind = .string, .required = true, .description = "Android, iOS, Linux, macOS, visionOS, Web, or Windows Desktop (Windows also works)" },
    .{ .long = "filter", .kind = .string, .description = "Only options whose name contains this, e.g. icon or keystore" },
};
const apply_options = [_]spec.OptionSpec{
    root_option,
    .{ .long = "intent", .kind = .path, .description = "Intent JSON file: {\"presets\": [{\"name\": \"Windows\", \"platform\": \"Windows Desktop\", \"export_path\": \"build/windows/game.exe\", \"runnable\": true, \"options\": {\"binary_format/embed_pck\": true}}], \"remove\": [\"Old\"]}" },
    .{ .long = "intent-json", .kind = .string, .description = "The intent itself, instead of a file; the same document the intent option describes" },
    .{ .long = "file", .kind = .path, .description = "Alias for --intent", .advanced = true },
    .{ .long = "dry-run", .kind = .flag, .description = "Check and apply in memory without writing either file" },
};
const build_options = [_]spec.OptionSpec{
    root_option,
    .{ .long = "preset", .kind = .string, .description = "The preset to export, by name (this or all)" },
    .{ .long = "all", .kind = .flag, .description = "Export every preset to its own export_path, carrying on past a failure and reporting each" },
    .{ .long = "output", .kind = .path, .description = "Output file, relative to the project root or absolute; default the preset's export_path" },
    .{ .long = "debug", .kind = .flag, .description = "Export with the debug template (--export-debug)" },
    .{ .long = "pack", .kind = .flag, .description = "Export only the .pck or .zip, no executable (--export-pack)" },
    project.godot_option,
};

pub fn commands() spec.CommandSpec {
    return .{
        .name = "export",
        .summary = "Export presets in export_presets.cfg, and the export itself",
        .description = "Creates and edits export presets the way the editor writes them: every option the platform defines, in the editor's order, with secrets (keystore passwords, the script encryption key) in .godot/export_credentials.cfg rather than the committed file. The option list comes from the editor of the project's Godot version (config/features), or the newest one godot-cli has for a project that names none.",
        .children = &.{
            .{
                .name = "list",
                .summary = "List export presets",
                .description = "Each preset's name, platform, runnable flag, its preset keys (export_path, export_filter, custom_features, ...), and the options that differ from the default. A preset Godot would skip (a platform it does not match, or one past a gap in the numbering) is listed with godot_skips saying why and how to fix it. Secret values are never shown, only whether they are set. Result data: path, exists, presets, godot_version, project_godot_version, summary.",
                .options = &list_options,
                .handler = listHandler,
            },
            .{
                .name = "show",
                .summary = "Show one export preset",
                .description = "One preset, as list shows it; with --all-options, every option the platform has and its value, the default where the file sets none, rather than only the changed ones. Secret values are never shown. Result data: the preset's fields, changed_options or options, summary.",
                .options = &show_options,
                .handler = showHandler,
            },
            .{
                .name = "options",
                .summary = "List the export options a platform has",
                .description = "Every option the platform's exporter defines in this Godot version: name, default, type, choices for an option with a fixed set, and whether it is secret. Also the preset keys every platform shares (export_path, export_filter, include_filter, ...); filter narrows those too, so preset_keys can be empty. Use it to find an option's name before setting it with project export apply. Result data: platform, options, preset_keys, godot_version, summary.",
                .options = &options_options,
                .handler = optionsHandler,
            },
            .{
                .name = "apply",
                .summary = "Create, update, rename, or remove export presets",
                .description = "Applies {\"presets\": [...], \"remove\": [...]}. A preset entry is matched by name and created if there is none, which needs platform (Android, iOS, Linux, macOS, visionOS, Web, Windows Desktop; Windows, HTML5 and the like are accepted and written as the name Godot matches). Fields: name, platform, rename, runnable (one per platform), export_path, export_filter (all_resources, scenes, resources, exclude, customized) with export_files, include_filter and exclude_filter (a string or a list), custom_features (a string or a list), dedicated_server, script_export_mode (text, binary_tokens, compressed_binary_tokens), the patch and encryption keys, script_encryption_key, and options: {name: value} with names from project export options. Option values are typed by the option: true/false, numbers, strings, a choice's label (\"AAB\" for gradle_build/export_format), arrays of strings. An option the platform does not have is refused with the nearest name, unless the entry sets allow_unknown_options for an addon's own option. The whole preset is written as the editor writes it, every option included, so opening the project in the editor changes nothing. Secret options go to .godot/export_credentials.cfg. An export_path inside the project gets a .gdignore in its top folder (build/ for build/windows/game.exe), so Godot neither imports builds nor packs one into the next. A preset whose platform Godot does not match (Windows) is corrected by giving the right one, keeping its settings; presets past a gap in the numbering are kept and renumbered; secrets found in export_presets.cfg move to the credentials file. Result data: path, credentials_path, created, updated, removed, changes (for each updated preset, every value the apply changed as {key, old, new}, keys being [preset.N] keys, options/<name>, platform, rename or runnable; a secret's values are never shown, only secret: true; anything not listed was kept), secrets_written and secrets_moved (names only), gdignore_created, presets, dry_run, summary.",
                .options = &apply_options,
                .handler = applyHandler,
            },
            .{
                .name = "validate",
                .summary = "Check export_presets.cfg for what Godot would drop or reject",
                .description = "Errors: a platform Godot does not know (it skips the preset and drops it on its next save; Windows must be Windows Desktop), a gap in the preset numbering (Godot stops reading at the gap), two presets with one name, an option value of the wrong type or outside its choices, and Android settings that need gradle_build/use_gradle_build (an AAB, compressed native libraries, swipe to dismiss, a min SDK), which Godot refuses to export. Warnings: missing include_filter or exclude_filter, no export_path, an export_path inside the project in a folder with no .gdignore (Godot imports the build and packs it into the next), a keystore or template file that does not exist on this machine, an option the platform does not have, a secret in the committed file, a res:// path that does not exist, a runnable entry naming no preset. matches_editor_save says whether the editor would leave the file as it is. Each issue names the file and line it is about: an option set only in .godot/export_credentials.cfg, such as a keystore path or password, points there. Exits non-zero when there is an error. Result data: path, exists, issues (severity, kind, preset, message, file, line), error_count, warning_count, matches_editor_save, summary.",
                .options = &list_options,
                .handler = validateHandler,
            },
            .{
                .name = "build",
                .summary = "Export the project with a preset (runs Godot)",
                .description = "Runs godot --headless --export-release (or --export-debug, --export-pack) with the preset, creating the output folder first, and a .gdignore in its top folder inside the project (build/ for build/windows/game.exe) so Godot neither imports the build nor packs it into the next one. Needs the export templates for this exact Godot version; without them it fails as export_templates_missing, with missing_template naming the path Godot looked in. Any other failure is export_failed, with Godot's ERROR lines and the reasons listed under them in errors. Result data: preset, platform, mode, output, output_path, exit, files (each output file and its size), errors (Godot's ERROR lines and their reasons), missing_template, gdignore_created, stdout_tail and stderr_tail on failure, summary. With all instead of a preset, every preset is exported in turn to its export_path and a failure does not stop the rest: a preset Godot cannot find or with no export_path is skipped and says why. Result data then: mode, results (one per preset, as above, with ok, and failure_kind or skipped), built, failed, summary; it exits non-zero if any preset was not exported.",
                .options = &build_options,
                .handler = buildHandler,
            },
        },
    };
}
