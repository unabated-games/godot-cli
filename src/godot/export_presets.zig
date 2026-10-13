//! Export presets: `export_presets.cfg` and its secret half,
//! `.godot/export_credentials.cfg`.
//!
//! Read the way `EditorExport::load_config` reads them and written the way
//! `EditorExport::_save` writes them (editor/export/editor_export.cpp), so a
//! preset written here is the file the editor would write for it, down to
//! the option order. Three things about the editor shape all of it:
//!
//! - It writes every option a platform defines, defaults included, in the
//!   platform's own order. A preset with only the options someone set still
//!   exports, but the next save in the editor rewrites it in full.
//! - It reads `preset.0`, `preset.1`, ... and stops at the first gap, and it
//!   skips a preset whose `platform` it does not know. Either way the preset
//!   is gone from the file the next time the editor saves it.
//! - Options marked secret (keystore passwords, the script encryption key)
//!   go to `.godot/export_credentials.cfg`, which is not committed.

const std = @import("std");
const config_file = @import("config_file.zig");
const export_options = @import("export_options.zig");
const types = export_options.types;
const lex = @import("variant/lex.zig");
const value_mod = @import("variant/value.zig");
const parse_mod = @import("variant/parse.zig");

pub const Entry = config_file.Entry;

pub const runnable_section = "runnable_presets";

pub const Preset = struct {
    name: []const u8,
    platform: []const u8,
    /// The `[preset.N]` entries as read, in file order.
    main: std.ArrayList(Entry),
    /// Options from both files: the presets file's, then any only in the
    /// credentials file. `render` puts them in the platform's order.
    options: std.ArrayList(Entry),
    /// The `[preset.N]` entries of the credentials file.
    credential_main: std.ArrayList(Entry),
    /// Option keys read from the presets file (as opposed to the credentials
    /// file): a secret here is one committed to version control.
    options_in_presets_file: std.StringHashMapUnmanaged(void) = .empty,
    /// Header line of `[preset.N]` in export_presets.cfg; 0 for a new preset.
    line: usize = 0,
    /// Read from past a gap in the numbering, where Godot never looks.
    after_gap: bool = false,

    pub fn mainValue(self: *const Preset, key: []const u8) ?[]const u8 {
        return getEntry(self.main.items, key);
    }

    pub fn option(self: *const Preset, key: []const u8) ?[]const u8 {
        return getEntry(self.options.items, key);
    }
};

pub const Presets = struct {
    presets: std.ArrayList(Preset),
    /// `[runnable_presets]`: platform name -> quoted preset name.
    runnable: std.ArrayList(Entry),
    /// Sections nothing reads, with their header lines: an options section
    /// with no preset, or anything unrecognised.
    stray: std.ArrayList(Entry),
    /// Presets read from past a gap in the numbering, with their header
    /// lines. Godot never loads these and drops them on its next save; they
    /// are kept here, and the next write renumbers them.
    gaps: std.ArrayList(Entry),
    exists: bool,

    pub fn find(self: *const Presets, name: []const u8) ?usize {
        for (self.presets.items, 0..) |preset, index| {
            if (std.mem.eql(u8, preset.name, name)) return index;
        }
        return null;
    }

    pub fn isRunnable(self: *const Presets, preset: *const Preset) bool {
        const named = getEntry(self.runnable.items, preset.platform) orelse return false;
        const unquoted = lex.parseQuotedString(std.heap.page_allocator, named) catch return false;
        defer std.heap.page_allocator.free(unquoted);
        return std.mem.eql(u8, unquoted, preset.name);
    }
};

fn getEntry(entries: []const Entry, key: []const u8) ?[]const u8 {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry.key, key)) return entry.value;
    }
    return null;
}

fn putEntry(arena: std.mem.Allocator, entries: *std.ArrayList(Entry), key: []const u8, value: []const u8) !void {
    for (entries.items) |*entry| {
        if (std.mem.eql(u8, entry.key, key)) {
            entry.value = value;
            return;
        }
    }
    try entries.append(arena, .{ .key = key, .value = value });
}

fn removeEntry(entries: *std.ArrayList(Entry), key: []const u8) bool {
    for (entries.items, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.key, key)) {
            _ = entries.orderedRemove(index);
            return true;
        }
    }
    return false;
}

/// Decoded string value, or the raw text when it is not a quoted string.
pub fn unquote(arena: std.mem.Allocator, text: []const u8) []const u8 {
    return lex.parseQuotedString(arena, text) catch text;
}

/// Both files' text (either may be absent) into presets, the way
/// `EditorExport::load_config` walks them.
pub fn load(arena: std.mem.Allocator, presets_text: ?[]const u8, credentials_text: ?[]const u8) !Presets {
    var result: Presets = .{ .presets = .empty, .runnable = .empty, .stray = .empty, .gaps = .empty, .exists = presets_text != null };
    const doc = try config_file.parse(arena, presets_text orelse "");
    const credentials = config_file.parse(arena, credentials_text orelse "") catch config_file.Document{ .sections = .empty };

    if (doc.find(runnable_section)) |section| {
        try result.runnable.appendSlice(arena, section.entries.items);
    }

    // Godot reads preset.0, preset.1, ... and stops at the first gap. A
    // writer that did the same would delete every preset after the gap, so
    // every numbered preset is read, in order, and renumbered on the next
    // write; `gaps` keeps what validate reports.
    var indexes: std.ArrayList(usize) = .empty;
    for (doc.sections.items) |section| {
        if (!std.mem.startsWith(u8, section.name, "preset.") or std.mem.endsWith(u8, section.name, ".options")) continue;
        if (presetIndexOf(section.name)) |n| try indexes.append(arena, n);
    }
    std.mem.sort(usize, indexes.items, {}, std.sort.asc(usize));

    for (indexes.items, 0..) |file_index, position| {
        const name = try std.fmt.allocPrint(arena, "preset.{d}", .{file_index});
        const section = doc.find(name).?;
        if (file_index != position) {
            try result.gaps.append(arena, .{ .key = name, .value = try std.fmt.allocPrint(arena, "{d}", .{section.line}) });
        }
        var preset: Preset = .{
            .name = unquote(arena, section.get("name") orelse "\"\""),
            .platform = unquote(arena, section.get("platform") orelse "\"\""),
            .main = .empty,
            .options = .empty,
            .credential_main = .empty,
            .line = section.line,
            .after_gap = file_index != position,
        };
        try preset.main.appendSlice(arena, section.entries.items);
        // Before 4.3 the Linux platform was "Linux/X11"; load_config reads it
        // as Linux and the next save writes Linux.
        if (std.mem.eql(u8, preset.platform, "Linux/X11")) preset.platform = "Linux";
        // Before 4.7 a preset said `runnable=true` itself; load_config still
        // honours it, and the next save moves it to [runnable_presets].
        if (preset.mainValue("runnable")) |legacy| {
            if (std.mem.eql(u8, legacy, "true") and getEntry(result.runnable.items, preset.platform) == null) {
                try result.runnable.append(arena, .{ .key = preset.platform, .value = try quote(arena, preset.name) });
            }
            _ = removeEntry(&preset.main, "runnable");
        }
        if (doc.find(try std.fmt.allocPrint(arena, "preset.{d}.options", .{file_index}))) |options| {
            for (options.entries.items) |entry| {
                try putEntry(arena, &preset.options, entry.key, entry.value);
                try preset.options_in_presets_file.put(arena, entry.key, {});
            }
        }
        if (credentials.find(name)) |secret_main| {
            try preset.credential_main.appendSlice(arena, secret_main.entries.items);
        }
        if (credentials.find(try std.fmt.allocPrint(arena, "preset.{d}.options", .{file_index}))) |secret_options| {
            for (secret_options.entries.items) |entry| try putEntry(arena, &preset.options, entry.key, entry.value);
        }
        try result.presets.append(arena, preset);
    }

    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.name, runnable_section)) continue;
        if (presetIndexOf(section.name)) |section_index| {
            if (std.mem.indexOfScalar(usize, indexes.items, section_index) != null) continue;
        }
        try result.stray.append(arena, .{ .key = section.name, .value = try std.fmt.allocPrint(arena, "{d}", .{section.line}) });
    }
    return result;
}

/// `preset.4` and `preset.4.options` -> 4.
fn presetIndexOf(section_name: []const u8) ?usize {
    if (!std.mem.startsWith(u8, section_name, "preset.")) return null;
    const rest = section_name["preset.".len..];
    const digits_end = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    if (digits_end < rest.len and !std.mem.eql(u8, rest[digits_end..], ".options")) return null;
    return std.fmt.parseInt(usize, rest[0..digits_end], 10) catch null;
}

pub const Rendered = struct {
    presets: []const u8,
    credentials: []const u8,
};

/// Both files as the editor's `_save` writes them for these presets.
pub fn render(arena: std.mem.Allocator, presets: *const Presets, table: *const types.Table) !Rendered {
    var main_sections: std.ArrayList(config_file.Section) = .empty;
    var secret_sections: std.ArrayList(config_file.Section) = .empty;

    // The editor's runnable map is filled as presets load, so it is written
    // in preset order, and only for a preset that exists.
    var runnable: std.ArrayList(Entry) = .empty;
    for (presets.presets.items) |*preset| {
        if (presets.isRunnable(preset) and getEntry(runnable.items, preset.platform) == null) {
            try runnable.append(arena, .{ .key = preset.platform, .value = try quote(arena, preset.name) });
        }
    }
    if (runnable.items.len > 0) {
        try main_sections.append(arena, .{ .name = runnable_section, .entries = runnable, .line = 0 });
    }

    for (presets.presets.items, 0..) |*preset, index| {
        const platform = export_options.findPlatform(table, preset.platform);

        var main: std.ArrayList(Entry) = .empty;
        const filter = unquote(arena, preset.mainValue("export_filter") orelse "\"all_resources\"");
        for (table.preset_keys) |key| {
            const value = if (std.mem.eql(u8, key.name, "name"))
                try quote(arena, preset.name)
            else if (std.mem.eql(u8, key.name, "platform"))
                try quote(arena, preset.platform)
            else
                preset.mainValue(key.name) orelse key.default;
            try main.append(arena, .{ .key = key.name, .value = value });
            if (std.mem.eql(u8, key.name, "export_filter")) {
                if (std.mem.eql(u8, filter, "customized")) {
                    try main.append(arena, .{ .key = "customized_files", .value = preset.mainValue("customized_files") orelse "{}" });
                } else if (filterTakesFiles(filter)) {
                    try main.append(arena, .{ .key = "export_files", .value = preset.mainValue("export_files") orelse "PackedStringArray()" });
                }
            }
        }
        // A key this table does not know is kept, at the end: it is more
        // likely a newer engine's than a mistake, and dropping it would lose
        // data. `project export validate` names it.
        for (preset.main.items) |entry| {
            if (getEntry(main.items, entry.key) != null) continue;
            if (std.mem.eql(u8, entry.key, "export_files") or std.mem.eql(u8, entry.key, "customized_files")) continue;
            try main.append(arena, entry);
        }

        // load_config starts from create_preset(), which holds every option
        // at its default in the platform's order, and sets the file's values
        // over them. So the order is always the platform's, whatever the
        // file's was, with anything the platform does not define after it.
        var public_options: std.ArrayList(Entry) = .empty;
        var secret_options: std.ArrayList(Entry) = .empty;
        if (platform) |p| {
            for (p.options) |o| {
                try (if (o.secret) &secret_options else &public_options).append(arena, .{ .key = o.name, .value = preset.option(o.name) orelse o.default });
            }
        }
        for (preset.options.items) |entry| {
            if (platform) |p| if (export_options.findOption(p, entry.key) != null) continue;
            try public_options.append(arena, entry);
        }

        try main_sections.append(arena, .{ .name = try std.fmt.allocPrint(arena, "preset.{d}", .{index}), .entries = main, .line = 0 });
        try main_sections.append(arena, .{ .name = try std.fmt.allocPrint(arena, "preset.{d}.options", .{index}), .entries = public_options, .line = 0 });

        var credential_main: std.ArrayList(Entry) = .empty;
        for (table.credential_keys) |key| {
            try credential_main.append(arena, .{ .key = key.name, .value = getEntry(preset.credential_main.items, key.name) orelse key.default });
        }
        try secret_sections.append(arena, .{ .name = try std.fmt.allocPrint(arena, "preset.{d}", .{index}), .entries = credential_main, .line = 0 });
        if (secret_options.items.len > 0) {
            try secret_sections.append(arena, .{ .name = try std.fmt.allocPrint(arena, "preset.{d}.options", .{index}), .entries = secret_options, .line = 0 });
        }
    }

    return .{
        .presets = try config_file.render(arena, main_sections.items),
        .credentials = try config_file.render(arena, secret_sections.items),
    };
}

fn filterTakesFiles(filter: []const u8) bool {
    return std.mem.eql(u8, filter, "scenes") or std.mem.eql(u8, filter, "resources") or std.mem.eql(u8, filter, "exclude");
}

pub const export_filters = [_][]const u8{ "all_resources", "scenes", "resources", "exclude", "customized" };

/// `EditorExportPreset::ScriptExportMode`, by the names the editor shows.
pub const script_export_modes = [_]types.Choice{
    .{ .label = "text", .value = "0" },
    .{ .label = "binary_tokens", .value = "1" },
    .{ .label = "compressed_binary_tokens", .value = "2" },
};

// ---------------------------------------------------------------------------
// Values from JSON

pub const ValueError = error{ OutOfMemory, InvalidValue };

fn quote(arena: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]const u8 {
    return lex.quoteString(arena, text) catch return error.OutOfMemory;
}

fn floatText(arena: std.mem.Allocator, value: f64) error{OutOfMemory}![]const u8 {
    return value_mod.formatScalarFloat(arena, value) catch return error.OutOfMemory;
}

/// The strings of `PackedStringArray("a", "b")`.
pub fn packedStrings(arena: std.mem.Allocator, text: []const u8) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, text, i, '"')) |open| {
        var j = open + 1;
        while (j < text.len and text[j] != '"') : (j += 1) {
            if (text[j] == '\\') j += 1;
        }
        if (j >= text.len) break;
        try out.append(arena, lex.parseQuotedString(arena, text[open .. j + 1]) catch text[open + 1 .. j]);
        i = j + 1;
    }
    return out.items;
}

pub const ValueProblem = struct {
    /// What was wrong, for the failure's hint.
    hint: []const u8 = "",
};

/// The kind of a preset key, from the text the editor writes by default.
pub fn kindOfDefault(text: []const u8) types.Kind {
    if (std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false")) return .bool;
    if (text.len > 0 and text[0] == '"') return .string;
    if (std.mem.startsWith(u8, text, "PackedStringArray(")) return .packed_string_array;
    if (std.mem.startsWith(u8, text, "Color(")) return .color;
    if (text.len > 0 and text[0] == '{') return .dictionary;
    if (text.len > 0 and text[0] == '[') return .array;
    if (std.mem.indexOfScalar(u8, text, '.') != null) return .float;
    _ = std.fmt.parseInt(i64, text, 10) catch return .other;
    return .int;
}

/// One JSON value as the Variant text the editor would write for an option
/// of this kind. `problem.hint` says why when it is refused.
pub fn valueText(
    arena: std.mem.Allocator,
    kind: types.Kind,
    choices: []const types.Choice,
    value: std.json.Value,
    problem: *ValueProblem,
) ValueError![]const u8 {
    if (choices.len > 0) {
        if (try matchChoice(arena, kind, choices, value)) |text| return text;
        var labels: std.ArrayList(u8) = .empty;
        for (choices, 0..) |choice, i| {
            if (i > 0) try labels.appendSlice(arena, ", ");
            try labels.appendSlice(arena, choice.label);
            if (kind == .int) try labels.print(arena, " ({s})", .{choice.value});
        }
        problem.hint = try std.fmt.allocPrint(arena, "one of: {s}", .{labels.items});
        return error.InvalidValue;
    }
    switch (kind) {
        .bool => switch (value) {
            .bool => |b| return if (b) "true" else "false",
            .string => |s| {
                if (std.mem.eql(u8, s, "true") or std.mem.eql(u8, s, "false")) return arena.dupe(u8, s);
            },
            else => {},
        },
        .int => switch (value) {
            .integer => |i| return std.fmt.allocPrint(arena, "{d}", .{i}),
            .float => |f| if (@floor(f) == f and @abs(f) < 1e15) return std.fmt.allocPrint(arena, "{d}", .{@as(i64, @intFromFloat(f))}),
            .string => |s| if (std.fmt.parseInt(i64, s, 10)) |i| return std.fmt.allocPrint(arena, "{d}", .{i}) else |_| {},
            else => {},
        },
        .float => switch (value) {
            .integer => |i| return floatText(arena, @floatFromInt(i)),
            .float => |f| return floatText(arena, f),
            .string => |s| if (std.fmt.parseFloat(f64, s)) |f| return floatText(arena, f) else |_| {},
            else => {},
        },
        .string => switch (value) {
            .string => |s| return quote(arena, s),
            .integer, .float, .bool => {
                problem.hint = "a string; quote the value";
                return error.InvalidValue;
            },
            else => {},
        },
        .packed_string_array => switch (value) {
            .array => |items| {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(arena, "PackedStringArray(");
                for (items.items, 0..) |item, i| {
                    if (item != .string) {
                        problem.hint = "an array of strings";
                        return error.InvalidValue;
                    }
                    if (i > 0) try out.appendSlice(arena, ", ");
                    try out.appendSlice(arena, try quote(arena, item.string));
                }
                try out.append(arena, ')');
                return out.items;
            },
            .string => |s| if (std.mem.startsWith(u8, s, "PackedStringArray(")) return verbatim(arena, s, problem),
            else => {},
        },
        .dictionary => switch (value) {
            .object => |object| return dictionaryText(arena, object, problem),
            .string => |s| if (s.len > 0 and s[0] == '{') return verbatim(arena, s, problem),
            else => {},
        },
        .color => switch (value) {
            .string => |s| {
                if (s.len > 0 and s[0] == '#') {
                    const rgba = lex.parseHexColor(s) catch {
                        problem.hint = "a #rrggbb or #rrggbbaa colour, or Color(r, g, b, a)";
                        return error.InvalidValue;
                    };
                    var parts: [4][]const u8 = undefined;
                    for (rgba, 0..) |component, i| parts[i] = lex.formatGodotFloat(arena, component) catch return error.OutOfMemory;
                    return std.fmt.allocPrint(arena, "Color({s}, {s}, {s}, {s})", .{ parts[0], parts[1], parts[2], parts[3] });
                }
                if (std.mem.startsWith(u8, s, "Color(")) return verbatim(arena, s, problem);
            },
            else => {},
        },
        .array, .other => switch (value) {
            .string => |s| return verbatim(arena, s, problem),
            else => {},
        },
    }
    if (problem.hint.len == 0) problem.hint = switch (kind) {
        .bool => "true or false",
        .int => "a whole number",
        .float => "a number",
        .string => "a string",
        .packed_string_array => "an array of strings",
        .dictionary => "a JSON object of strings and numbers",
        .color => "a #rrggbb or #rrggbbaa colour, or Color(r, g, b, a)",
        .array, .other => "Godot Variant text, as a string",
    };
    return error.InvalidValue;
}

fn matchChoice(arena: std.mem.Allocator, kind: types.Kind, choices: []const types.Choice, value: std.json.Value) ValueError!?[]const u8 {
    const given: []const u8 = switch (value) {
        .string => |s| s,
        .integer => |i| try std.fmt.allocPrint(arena, "{d}", .{i}),
        else => return null,
    };
    for (choices) |choice| {
        if (std.ascii.eqlIgnoreCase(choice.label, given)) return choice.value;
        if (kind == .int and std.mem.eql(u8, choice.value, given)) return choice.value;
    }
    // "AAB" for "Export AAB": a label's last word, when only one matches.
    var found: ?[]const u8 = null;
    for (choices) |choice| {
        const space = std.mem.lastIndexOfScalar(u8, choice.label, ' ') orelse continue;
        if (std.ascii.eqlIgnoreCase(choice.label[space + 1 ..], given)) {
            if (found != null) return null;
            found = choice.value;
        }
    }
    return found;
}

/// Godot text given as a string: checked to parse, written as given.
fn verbatim(arena: std.mem.Allocator, text: []const u8, problem: *ValueProblem) ValueError![]const u8 {
    var parsed = parse_mod.parsePropertyValue(arena, text) catch {
        problem.hint = "this does not parse as Godot Variant text";
        return error.InvalidValue;
    };
    parsed.deinit(arena);
    return arena.dupe(u8, text);
}

/// `VariantWriter`'s dictionary: `{}` when empty, otherwise one entry a line
/// with keys in sorted order.
fn dictionaryText(arena: std.mem.Allocator, object: std.json.ObjectMap, problem: *ValueProblem) ValueError![]const u8 {
    if (object.count() == 0) return "{}";
    const keys = try arena.alloc([]const u8, object.count());
    var it = object.iterator();
    var n: usize = 0;
    while (it.next()) |entry| : (n += 1) keys[n] = entry.key_ptr.*;
    std.mem.sort([]const u8, keys, {}, struct {
        fn less(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.less);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "{\n");
    for (keys, 0..) |key, i| {
        try out.appendSlice(arena, try quote(arena, key));
        try out.appendSlice(arena, ": ");
        const item = object.get(key).?;
        const text: []const u8 = switch (item) {
            .string => |s| try quote(arena, s),
            .integer => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
            .float => |v| try floatText(arena, v),
            .bool => |v| if (v) "true" else "false",
            else => {
                problem.hint = "a dictionary of strings, numbers and booleans";
                return error.InvalidValue;
            },
        };
        try out.appendSlice(arena, text);
        try out.appendSlice(arena, if (i + 1 < keys.len) ",\n" else "\n");
    }
    try out.append(arena, '}');
    return out.items;
}

// ---------------------------------------------------------------------------
// Applying an intent

pub const ApplyError = error{ OutOfMemory, InvalidIntent };

/// Why an intent was refused, for the failure's details.
pub const Refusal = struct {
    field: []const u8 = "",
    value: []const u8 = "",
    hint: []const u8 = "",
    kind: []const u8 = "invalid_intent",
};

pub const Applied = struct {
    created: std.ArrayList([]const u8) = .empty,
    updated: std.ArrayList([]const u8) = .empty,
    removed: std.ArrayList([]const u8) = .empty,
    /// Secret keys written to the credentials file, by name only.
    secrets: std.ArrayList([]const u8) = .empty,
    messages: std.ArrayList([]const u8) = .empty,
};

pub const preset_fields = [_][]const u8{
    "name",                        "platform",                           "rename",                     "runnable",
    "options",                     "allow_unknown_options",              "dedicated_server",           "custom_features",
    "export_filter",               "export_files",                       "customized_files",           "include_filter",
    "exclude_filter",              "export_path",                        "script_export_mode",         "patches",
    "patch_delta_encoding",        "patch_delta_compression_level_zstd", "patch_delta_min_reduction",  "patch_delta_include_filters",
    "patch_delta_exclude_filters", "encryption_include_filters",         "encryption_exclude_filters", "seed",
    "encrypt_pck",                 "encrypt_directory",                  "script_encryption_key",
};

const intent_fields = [_][]const u8{ "presets", "remove" };

fn listText(arena: std.mem.Allocator, names: []const []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (names, 0..) |name, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, name);
    }
    return out.items;
}

fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

fn refuse(refusal: *Refusal, value: Refusal) ApplyError {
    refusal.* = value;
    return error.InvalidIntent;
}

/// Apply `{"presets": [...], "remove": [...]}` to `presets`.
pub fn apply(
    arena: std.mem.Allocator,
    presets: *Presets,
    table: *const types.Table,
    intent: std.json.Value,
    refusal: *Refusal,
) ApplyError!Applied {
    var applied: Applied = .{};
    if (intent != .object) return refuse(refusal, .{ .hint = "the intent is a JSON object: {\"presets\": [...], \"remove\": [...]}" });
    var top = intent.object.iterator();
    while (top.next()) |entry| {
        if (!contains(&intent_fields, entry.key_ptr.*)) {
            return refuse(refusal, .{ .kind = "unknown_field", .field = entry.key_ptr.*, .hint = try std.fmt.allocPrint(arena, "the intent takes: {s}", .{try listText(arena, &intent_fields)}) });
        }
    }

    if (intent.object.get("remove")) |remove| {
        if (remove != .array) return refuse(refusal, .{ .field = "remove", .hint = "an array of preset names" });
        for (remove.array.items) |item| {
            if (item != .string) return refuse(refusal, .{ .field = "remove", .hint = "an array of preset names" });
            const index = presets.find(item.string) orelse return refuse(refusal, .{
                .kind = "preset_not_found",
                .field = "remove",
                .value = item.string,
                .hint = try std.fmt.allocPrint(arena, "presets: {s}", .{try presetNames(arena, presets)}),
            });
            const preset = presets.presets.orderedRemove(index);
            if (getEntry(presets.runnable.items, preset.platform)) |named| {
                if (std.mem.eql(u8, unquote(arena, named), preset.name)) _ = removeEntry(&presets.runnable, preset.platform);
            }
            try applied.removed.append(arena, preset.name);
        }
    }

    const list = intent.object.get("presets") orelse return applied;
    if (list != .array) return refuse(refusal, .{ .field = "presets", .hint = "an array of preset objects, each with a name" });
    for (list.array.items, 0..) |item, item_index| {
        try applyOne(arena, presets, table, item, item_index, &applied, refusal);
    }
    return applied;
}

fn presetNames(arena: std.mem.Allocator, presets: *const Presets) ![]const u8 {
    if (presets.presets.items.len == 0) return "(none yet)";
    var names: std.ArrayList([]const u8) = .empty;
    for (presets.presets.items) |preset| try names.append(arena, preset.name);
    return listText(arena, names.items);
}

fn platformNames(arena: std.mem.Allocator, table: *const types.Table) ![]const u8 {
    var names: std.ArrayList([]const u8) = .empty;
    for (table.platforms) |platform| try names.append(arena, platform.name);
    return listText(arena, names.items);
}

fn applyOne(
    arena: std.mem.Allocator,
    presets: *Presets,
    table: *const types.Table,
    item: std.json.Value,
    item_index: usize,
    applied: *Applied,
    refusal: *Refusal,
) ApplyError!void {
    const at = try std.fmt.allocPrint(arena, "presets[{d}]", .{item_index});
    if (item != .object) return refuse(refusal, .{ .field = at, .hint = "a preset object with at least a name" });
    const object = item.object;
    var fields = object.iterator();
    while (fields.next()) |entry| {
        if (!contains(&preset_fields, entry.key_ptr.*)) {
            return refuse(refusal, .{
                .kind = "unknown_field",
                .field = try std.fmt.allocPrint(arena, "{s}.{s}", .{ at, entry.key_ptr.* }),
                .hint = try std.fmt.allocPrint(arena, "a preset takes: {s}. Platform settings go under options", .{try listText(arena, &preset_fields)}),
            });
        }
    }
    const name_value = object.get("name") orelse return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.name", .{at}), .hint = "every preset needs a name; it is how godot --export-release finds it" });
    if (name_value != .string or name_value.string.len == 0) return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.name", .{at}), .hint = "a non-empty string" });
    const name = name_value.string;

    var platform: ?*const types.Platform = null;
    if (object.get("platform")) |given| {
        if (given != .string) return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.platform", .{at}), .hint = "a platform name" });
        platform = export_options.resolvePlatform(table, given.string) orelse return refuse(refusal, .{
            .kind = "unknown_platform",
            .field = try std.fmt.allocPrint(arena, "{s}.platform", .{at}),
            .value = given.string,
            .hint = try std.fmt.allocPrint(arena, "one of: {s}. Godot skips a preset whose platform it does not know and drops it on its next save", .{try platformNames(arena, table)}),
        });
        if (!std.mem.eql(u8, platform.?.name, given.string)) {
            try applied.messages.append(arena, try std.fmt.allocPrint(arena, "{s}: platform \"{s}\" written as \"{s}\", the name Godot matches", .{ name, given.string, platform.?.name }));
        }
    }

    const index = presets.find(name) orelse blk: {
        const chosen = platform orelse return refuse(refusal, .{
            .field = try std.fmt.allocPrint(arena, "{s}.platform", .{at}),
            .value = name,
            .hint = try std.fmt.allocPrint(arena, "no preset is named \"{s}\", and creating one needs a platform: {s}. Existing presets: {s}", .{ name, try platformNames(arena, table), try presetNames(arena, presets) }),
        });
        try presets.presets.append(arena, .{
            .name = name,
            .platform = chosen.name,
            .main = .empty,
            .options = .empty,
            .credential_main = .empty,
        });
        try applied.created.append(arena, name);
        break :blk presets.presets.items.len - 1;
    };
    const preset = &presets.presets.items[index];
    const created = applied.created.items.len > 0 and std.mem.eql(u8, applied.created.items[applied.created.items.len - 1], name) and preset.line == 0;
    if (!created) {
        try applied.updated.append(arena, name);
        if (platform) |p| {
            // A platform Godot does not match ("Windows") can be corrected
            // to the one it means; a real platform cannot be swapped for
            // another, because the options are the platform's own.
            const meant = export_options.resolvePlatform(table, preset.platform);
            if (export_options.findPlatform(table, preset.platform) == null and meant != null and meant.? == p) {
                if (getEntry(presets.runnable.items, preset.platform)) |named| {
                    if (std.mem.eql(u8, unquote(arena, named), preset.name)) {
                        _ = removeEntry(&presets.runnable, preset.platform);
                        try putEntry(arena, &presets.runnable, p.name, try quote(arena, preset.name));
                    }
                }
                try applied.messages.append(arena, try std.fmt.allocPrint(arena, "{s}: platform \"{s}\" corrected to \"{s}\", the name Godot matches; until now Godot skipped this preset", .{ name, preset.platform, p.name }));
                preset.platform = p.name;
            } else if (!std.mem.eql(u8, p.name, preset.platform)) {
                return refuse(refusal, .{
                    .field = try std.fmt.allocPrint(arena, "{s}.platform", .{at}),
                    .value = p.name,
                    .hint = try std.fmt.allocPrint(arena, "\"{s}\" is a {s} preset; a preset cannot change platform. Remove it and create a new one", .{ name, preset.platform }),
                });
            }
        }
    }
    const preset_platform = export_options.findPlatform(table, preset.platform);
    if (preset_platform == null and object.get("options") != null and !created) {
        return refuse(refusal, .{
            .kind = "unknown_platform",
            .field = try std.fmt.allocPrint(arena, "{s}.platform", .{at}),
            .value = preset.platform,
            .hint = if (export_options.resolvePlatform(table, preset.platform)) |meant|
                try std.fmt.allocPrint(arena, "this preset's platform \"{s}\" is not one Godot matches, so its options cannot be checked; give \"platform\": \"{s}\" in the same entry to correct it", .{ preset.platform, meant.name })
            else
                try std.fmt.allocPrint(arena, "this preset's platform \"{s}\" is not one Godot {s} exports to; give a platform in the same entry to correct it", .{ preset.platform, table.minor }),
        });
    }

    // Keys of [preset.N], typed by the text the editor writes by default.
    for (table.preset_keys) |key| {
        if (std.mem.eql(u8, key.name, "name") or std.mem.eql(u8, key.name, "platform")) continue;
        const given = object.get(key.name) orelse continue;
        const field = try std.fmt.allocPrint(arena, "{s}.{s}", .{ at, key.name });
        var problem: ValueProblem = .{};
        const text = presetKeyText(arena, key, given, &problem) catch |err| switch (err) {
            error.InvalidValue => return refuse(refusal, .{ .kind = "invalid_value", .field = field, .value = try jsonText(arena, given), .hint = problem.hint }),
            error.OutOfMemory => return error.OutOfMemory,
        };
        try putEntry(arena, &preset.main, key.name, text);
    }
    if (object.get("export_files")) |given| {
        var problem: ValueProblem = .{};
        const text = valueText(arena, .packed_string_array, &.{}, given, &problem) catch return refuse(refusal, .{ .kind = "invalid_value", .field = try std.fmt.allocPrint(arena, "{s}.export_files", .{at}), .hint = "an array of res:// paths" });
        try putEntry(arena, &preset.main, "export_files", text);
        const filter = unquote(arena, preset.mainValue("export_filter") orelse "\"all_resources\"");
        if (!filterTakesFiles(filter)) {
            try applied.messages.append(arena, try std.fmt.allocPrint(arena, "{s}: export_files only counts with export_filter scenes, resources or exclude; this preset's is {s}", .{ name, filter }));
        }
    }
    if (object.get("customized_files")) |given| {
        var problem: ValueProblem = .{};
        const text = valueText(arena, .dictionary, &.{}, given, &problem) catch return refuse(refusal, .{ .kind = "invalid_value", .field = try std.fmt.allocPrint(arena, "{s}.customized_files", .{at}), .hint = "an object of res:// path to strip, keep or remove" });
        try putEntry(arena, &preset.main, "customized_files", text);
    }
    if (object.get("script_encryption_key")) |given| {
        if (given != .string) return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.script_encryption_key", .{at}), .hint = "a string of 64 hex digits" });
        try putEntry(arena, &preset.credential_main, "script_encryption_key", try quote(arena, given.string));
        try applied.secrets.append(arena, try std.fmt.allocPrint(arena, "{s}: script_encryption_key", .{name}));
    }

    if (object.get("options")) |options| {
        if (options != .object) return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.options", .{at}), .hint = "an object of option name to value, e.g. {\"binary_format/embed_pck\": true}" });
        const allow_unknown = if (object.get("allow_unknown_options")) |a| a == .bool and a.bool else false;
        var it = options.object.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const field = try std.fmt.allocPrint(arena, "{s}.options.{s}", .{ at, key });
            const known = if (preset_platform) |p| export_options.findOption(p, key) else null;
            var problem: ValueProblem = .{};
            const text = if (known) |o|
                valueText(arena, o.kind, o.choices, entry.value_ptr.*, &problem) catch |err| switch (err) {
                    error.InvalidValue => return refuse(refusal, .{
                        .kind = "invalid_value",
                        .field = field,
                        .value = try jsonText(arena, entry.value_ptr.*),
                        .hint = try std.fmt.allocPrint(arena, "{s} takes {s}; its default is {s}", .{ key, problem.hint, o.default }),
                    }),
                    error.OutOfMemory => return error.OutOfMemory,
                }
            else blk: {
                if (!allow_unknown and preset_platform != null) {
                    const suggestion = export_options.nearestOption(preset_platform.?, key);
                    return refuse(refusal, .{
                        .kind = "unknown_option",
                        .field = field,
                        .value = key,
                        .hint = if (suggestion) |s|
                            try std.fmt.allocPrint(arena, "{s} has no option {s} in Godot {s}; did you mean {s}? project export options lists them. An addon's own option takes allow_unknown_options: true", .{ preset.platform, key, table.minor, s })
                        else
                            try std.fmt.allocPrint(arena, "{s} has no option {s} in Godot {s}; project export options --platform \"{s}\" lists them. An addon's own option takes allow_unknown_options: true", .{ preset.platform, key, table.minor, preset.platform }),
                    });
                }
                // An addon's option: no table to type it by.
                break :blk switch (entry.value_ptr.*) {
                    .bool => |b| @as([]const u8, if (b) "true" else "false"),
                    .integer => |v| try std.fmt.allocPrint(arena, "{d}", .{v}),
                    .float => |v| try floatText(arena, v),
                    .string => |s| try quote(arena, s),
                    else => return refuse(refusal, .{ .kind = "invalid_value", .field = field, .hint = "an unknown option takes a boolean, number or string" }),
                };
            };
            try putEntry(arena, &preset.options, key, text);
            if (known) |o| if (o.secret) {
                try applied.secrets.append(arena, try std.fmt.allocPrint(arena, "{s}: {s}", .{ name, key }));
            };
        }
    }

    if (object.get("rename")) |rename| {
        if (rename != .string or rename.string.len == 0) return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.rename", .{at}), .hint = "the new name, a non-empty string" });
        if (presets.find(rename.string) != null) return refuse(refusal, .{ .kind = "duplicate_name", .field = try std.fmt.allocPrint(arena, "{s}.rename", .{at}), .value = rename.string, .hint = "another preset already has this name" });
        if (getEntry(presets.runnable.items, preset.platform)) |named| {
            if (std.mem.eql(u8, unquote(arena, named), preset.name)) {
                try putEntry(arena, &presets.runnable, preset.platform, try quote(arena, rename.string));
            }
        }
        preset.name = rename.string;
    }

    if (object.get("runnable")) |runnable| {
        if (runnable != .bool) return refuse(refusal, .{ .field = try std.fmt.allocPrint(arena, "{s}.runnable", .{at}), .hint = "true or false" });
        if (runnable.bool) {
            if (getEntry(presets.runnable.items, preset.platform)) |previous| {
                const previous_name = unquote(arena, previous);
                if (!std.mem.eql(u8, previous_name, preset.name)) {
                    try applied.messages.append(arena, try std.fmt.allocPrint(arena, "{s} is now the runnable {s} preset, in place of {s}: a platform has one", .{ preset.name, preset.platform, previous_name }));
                }
            }
            try putEntry(arena, &presets.runnable, preset.platform, try quote(arena, preset.name));
        } else if (getEntry(presets.runnable.items, preset.platform)) |named| {
            if (std.mem.eql(u8, unquote(arena, named), preset.name)) _ = removeEntry(&presets.runnable, preset.platform);
        }
    }
}

fn presetKeyText(arena: std.mem.Allocator, key: types.Key, given: std.json.Value, problem: *ValueProblem) ValueError![]const u8 {
    if (std.mem.eql(u8, key.name, "export_filter")) {
        if (given == .string) {
            for (export_filters) |filter| {
                if (std.mem.eql(u8, filter, given.string)) return quote(arena, filter);
            }
        }
        problem.hint = "one of: all_resources, scenes, resources, exclude, customized";
        return error.InvalidValue;
    }
    if (std.mem.eql(u8, key.name, "script_export_mode")) {
        return valueText(arena, .int, &script_export_modes, given, problem);
    }
    // Filters and features are comma-separated strings in the file; a list
    // is the easier thing to give.
    const comma_lists = [_][]const u8{ "custom_features", "include_filter", "exclude_filter", "encryption_include_filters", "encryption_exclude_filters", "patch_delta_include_filters", "patch_delta_exclude_filters" };
    if (contains(&comma_lists, key.name) and given == .array) {
        var joined: std.ArrayList(u8) = .empty;
        for (given.array.items, 0..) |item, i| {
            if (item != .string) {
                problem.hint = "a string, or an array of strings";
                return error.InvalidValue;
            }
            if (i > 0) try joined.appendSlice(arena, ", ");
            try joined.appendSlice(arena, item.string);
        }
        return quote(arena, joined.items);
    }
    return valueText(arena, kindOfDefault(key.default), &.{}, given, problem);
}

fn jsonText(arena: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, value, .{}) catch return error.OutOfMemory;
}

// ---------------------------------------------------------------------------
// Validation

pub const Severity = enum { @"error", warning };

pub const Issue = struct {
    severity: Severity,
    kind: []const u8,
    preset: ?[]const u8 = null,
    message: []const u8,
    line: usize = 0,
};

/// `exists` answers whether a path names a file: a `res://` path or a
/// relative one inside the project, an absolute one on this machine.
pub fn validate(
    arena: std.mem.Allocator,
    presets: *const Presets,
    table: *const types.Table,
    exists: *const fn (ctx: *anyopaque, path: []const u8) bool,
    ctx: *anyopaque,
) ![]Issue {
    var issues: std.ArrayList(Issue) = .empty;

    for (presets.gaps.items) |gap| {
        try issues.append(arena, .{
            .severity = .@"error",
            .kind = "preset_numbering_gap",
            .line = std.fmt.parseInt(usize, gap.value, 10) catch 0,
            .message = try std.fmt.allocPrint(arena, "[{s}] comes after a gap in the numbering. Godot reads preset.0, preset.1, ... and stops at the first missing one, so it never loads this preset and drops it on its next save. Any project export apply renumbers the presets with no gaps, this one included (an empty intent, {{}}, does only that)", .{gap.key}),
        });
    }
    for (presets.stray.items) |stray| {
        try issues.append(arena, .{
            .severity = .warning,
            .kind = "stray_section",
            .line = std.fmt.parseInt(usize, stray.value, 10) catch 0,
            .message = try std.fmt.allocPrint(arena, "[{s}] is not a section Godot reads from export_presets.cfg; its next save drops it, and so does project export apply", .{stray.key}),
        });
    }

    for (presets.presets.items, 0..) |*preset, index| {
        for (presets.presets.items[0..index]) |earlier| {
            if (std.mem.eql(u8, earlier.name, preset.name)) {
                try issues.append(arena, .{ .severity = .@"error", .kind = "duplicate_preset_name", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "two presets are named \"{s}\"; godot --export-release finds a preset by name and takes the first", .{preset.name}) });
                break;
            }
        }
        // A platform Godot does not match is an error, but the rest of the
        // preset is still checked (against the platform it plainly means,
        // when there is one), so one run reports everything.
        const exact = export_options.findPlatform(table, preset.platform);
        const checked_platform = exact orelse export_options.resolvePlatform(table, preset.platform);
        if (exact == null) {
            const suggestion = checked_platform;
            try issues.append(arena, .{
                .severity = .@"error",
                .kind = "unknown_platform",
                .preset = preset.name,
                .line = preset.line,
                .message = if (suggestion) |s|
                    try std.fmt.allocPrint(arena, "platform \"{s}\" is not a name Godot matches; it means \"{s}\". Godot skips this preset when it loads the file and drops it on its next save", .{ preset.platform, s.name })
                else
                    try std.fmt.allocPrint(arena, "platform \"{s}\" is not one Godot {s} exports to ({s}). Godot skips this preset when it loads the file and drops it on its next save, unless an addon adds the platform", .{ preset.platform, table.minor, try platformNames(arena, table) }),
            });
        }

        for ([_][]const u8{ "include_filter", "exclude_filter" }) |key| {
            if (preset.mainValue(key) == null) {
                try issues.append(arena, .{ .severity = .warning, .kind = "missing_preset_key", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "no {s}; Godot exports anyway but logs an error every time it loads the presets. project export apply writes the full preset", .{key}) });
            }
        }
        const filter = unquote(arena, preset.mainValue("export_filter") orelse "\"all_resources\"");
        if (!contains(&export_filters, filter)) {
            try issues.append(arena, .{ .severity = .@"error", .kind = "invalid_value", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "export_filter \"{s}\" is not one Godot reads (all_resources, scenes, resources, exclude, customized); it falls back to exporting everything", .{filter}) });
        }
        if (filterTakesFiles(filter)) {
            if (preset.mainValue("export_files")) |files_text| {
                for (try packedStrings(arena, files_text)) |file| {
                    if (std.mem.startsWith(u8, file, "res://") and !exists(ctx, file)) {
                        try issues.append(arena, .{ .severity = .warning, .kind = "missing_export_file", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "export_files lists {s}, which does not exist; Godot drops it from the list when it loads the presets", .{file}) });
                    }
                }
            } else {
                try issues.append(arena, .{ .severity = .warning, .kind = "missing_preset_key", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "export_filter is {s} but no export_files are listed, so nothing is selected", .{filter}) });
            }
        }
        const export_path = unquote(arena, preset.mainValue("export_path") orelse "\"\"");
        if (export_path.len == 0) {
            try issues.append(arena, .{ .severity = .warning, .kind = "no_export_path", .preset = preset.name, .line = preset.line, .message = "export_path is empty, so godot --export-release and project export build need an output path every time" });
        } else if (buildFolderInProject(export_path)) |folder| {
            // Godot imports whatever lands in the project, and an
            // all_resources export then packs the last build into the next.
            const marker = try std.fmt.allocPrint(arena, "{s}/.gdignore", .{folder});
            if (!exists(ctx, marker)) {
                try issues.append(arena, .{ .severity = .warning, .kind = "export_path_not_ignored", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "export_path is inside the project, in {s}/, which has no .gdignore: Godot imports what is exported there, and the next export packs it into the game. project export build adds the .gdignore", .{folder}) });
            }
        } else if (std.mem.indexOfAny(u8, export_path, "/\\") == null) {
            try issues.append(arena, .{ .severity = .warning, .kind = "export_path_not_ignored", .preset = preset.name, .line = preset.line, .message = "export_path writes into the project root, where Godot imports what it finds and the next export packs it; use a folder such as build/" });
        }
        if (preset.mainValue("script_encryption_key")) |key| {
            if (unquote(arena, key).len > 0) {
                try issues.append(arena, .{ .severity = .warning, .kind = "secret_in_presets_file", .preset = preset.name, .line = preset.line, .message = "script_encryption_key is in export_presets.cfg, which is committed; Godot keeps it in .godot/export_credentials.cfg and moves it there on its next save" });
            }
        }
        for (preset.main.items) |entry| {
            if (export_options.findKey(table.preset_keys, entry.key) != null) continue;
            if (std.mem.eql(u8, entry.key, "export_files") or std.mem.eql(u8, entry.key, "customized_files") or std.mem.eql(u8, entry.key, "script_encryption_key")) continue;
            try issues.append(arena, .{ .severity = .warning, .kind = "unknown_preset_key", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "{s} is not a preset key in Godot {s}; the editor drops it on its next save", .{ entry.key, table.minor }) });
        }

        if (checked_platform) |platform| for (preset.options.items) |entry| {
            const option = export_options.findOption(platform, entry.key) orelse {
                try issues.append(arena, .{ .severity = .warning, .kind = "unknown_option", .preset = preset.name, .line = preset.line, .message = if (export_options.nearestOption(platform, entry.key)) |s|
                    try std.fmt.allocPrint(arena, "{s} has no option {s} in Godot {s} (did you mean {s}?); unless an addon adds it, Godot ignores it", .{ preset.platform, entry.key, table.minor, s })
                else
                    try std.fmt.allocPrint(arena, "{s} has no option {s} in Godot {s}; unless an addon adds it, Godot ignores it", .{ preset.platform, entry.key, table.minor }) });
                continue;
            };
            if (option.secret and preset.options_in_presets_file.contains(entry.key) and unquote(arena, entry.value).len > 0) {
                try issues.append(arena, .{ .severity = .warning, .kind = "secret_in_presets_file", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "{s} is a secret and is in export_presets.cfg, which is committed; Godot keeps it in .godot/export_credentials.cfg and moves it there on its next save", .{entry.key}) });
            }
            if (option.choices.len > 0) {
                var matched = false;
                for (option.choices) |choice| {
                    if (std.mem.eql(u8, choice.value, entry.value)) matched = true;
                }
                if (!matched) {
                    var problem: ValueProblem = .{};
                    _ = valueText(arena, option.kind, option.choices, .{ .string = "\x00" }, &problem) catch {};
                    try issues.append(arena, .{ .severity = .@"error", .kind = "invalid_value", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "{s} = {s} is not a value Godot offers for it; {s}", .{ entry.key, entry.value, problem.hint }) });
                }
                continue;
            }
            if (!textMatchesKind(arena, option.kind, entry.value)) {
                try issues.append(arena, .{ .severity = .@"error", .kind = "invalid_value", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "{s} = {s} is not the type Godot stores there (its default is {s})", .{ entry.key, entry.value, option.default }) });
                continue;
            }
            if (option.kind == .string) {
                const text = unquote(arena, entry.value);
                if (std.mem.startsWith(u8, text, "res://") and !exists(ctx, text)) {
                    try issues.append(arena, .{ .severity = .warning, .kind = "missing_file", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "{s} names {s}, which does not exist", .{ entry.key, text }) });
                } else if (text.len > 0 and isFileOption(entry.key) and !exists(ctx, text)) {
                    // A keystore lives outside the project, often only on
                    // the machine that signs. Its path is a secret's
                    // neighbour, so it is not echoed.
                    try issues.append(arena, .{ .severity = .warning, .kind = "missing_file", .preset = preset.name, .line = preset.line, .message = try std.fmt.allocPrint(arena, "{s} names a file that does not exist on this machine, so exporting here fails; it may exist where the release is signed", .{entry.key}) });
                }
            }
        };
        if (checked_platform) |platform| if (std.mem.eql(u8, platform.name, "Android")) try checkAndroid(arena, &issues, preset);
    }

    for (presets.runnable.items) |entry| {
        const named = unquote(arena, entry.value);
        var found = false;
        for (presets.presets.items) |preset| {
            if (std.mem.eql(u8, preset.platform, entry.key) and std.mem.eql(u8, preset.name, named)) found = true;
        }
        if (!found) {
            try issues.append(arena, .{ .severity = .warning, .kind = "runnable_preset_missing", .message = try std.fmt.allocPrint(arena, "[runnable_presets] makes \"{s}\" the runnable {s} preset, but there is no such {s} preset; Godot ignores the line and drops it on its next save", .{ named, entry.key, entry.key }) });
        }
    }
    return issues.items;
}

/// The export path's first folder, when the path is inside the project:
/// `build` for `build/windows/game.exe`.
fn buildFolderInProject(path: []const u8) ?[]const u8 {
    const relative = if (std.mem.startsWith(u8, path, "res://")) path["res://".len..] else path;
    if (relative.len == 0 or relative[0] == '/' or relative[0] == '\\' or std.mem.startsWith(u8, relative, "..")) return null;
    if (relative.len > 1 and relative[1] == ':') return null;
    const slash = std.mem.indexOfAny(u8, relative, "/\\") orelse return null;
    if (slash == 0 or std.mem.eql(u8, relative[0..slash], ".")) return null;
    return relative[0..slash];
}

/// Options that name a file Godot opens at export time.
fn isFileOption(key: []const u8) bool {
    const files = [_][]const u8{ "keystore/debug", "keystore/release", "custom_template/debug", "custom_template/release", "gradle_build/android_source_template" };
    return contains(&files, key);
}

/// The Android exporter's own rules (`get_export_option_warning` in
/// platform/android/export/export_plugin.cpp): settings that only work with
/// a Gradle build. Godot refuses the export with these messages.
fn checkAndroid(arena: std.mem.Allocator, issues: *std.ArrayList(Issue), preset: *const Preset) !void {
    const gradle = std.mem.eql(u8, preset.option("gradle_build/use_gradle_build") orelse "false", "true");
    if (gradle) return;
    const rules = [_]struct { key: []const u8, applies: *const fn ([]const u8) bool, message: []const u8 }{
        .{ .key = "gradle_build/export_format", .applies = struct {
            fn f(v: []const u8) bool {
                return std.mem.eql(u8, v, "1");
            }
        }.f, .message = "\"Export AAB\" is only valid when \"Use Gradle Build\" is enabled: set gradle_build/use_gradle_build to true" },
        .{ .key = "gradle_build/compress_native_libraries", .applies = isTrue, .message = "\"Compress Native Libraries\" is only valid when \"Use Gradle Build\" is enabled: set gradle_build/use_gradle_build to true" },
        .{ .key = "gesture/swipe_to_dismiss", .applies = isTrue, .message = "\"Use Gradle Build\" is required to enable \"Swipe to dismiss\": set gradle_build/use_gradle_build to true" },
        .{ .key = "gradle_build/min_sdk", .applies = struct {
            fn f(v: []const u8) bool {
                return !std.mem.eql(u8, v, "\"\"");
            }
        }.f, .message = "\"Min SDK\" can only be overridden when \"Use Gradle Build\" is enabled: set gradle_build/use_gradle_build to true" },
    };
    for (rules) |rule| {
        const value = preset.option(rule.key) orelse continue;
        if (rule.applies(value)) {
            try issues.append(arena, .{ .severity = .@"error", .kind = "needs_gradle_build", .preset = preset.name, .line = preset.line, .message = rule.message });
        }
    }
}

fn isTrue(value: []const u8) bool {
    return std.mem.eql(u8, value, "true");
}

fn textMatchesKind(arena: std.mem.Allocator, kind: types.Kind, text: []const u8) bool {
    return switch (kind) {
        .bool => std.mem.eql(u8, text, "true") or std.mem.eql(u8, text, "false"),
        .int => if (std.fmt.parseInt(i64, text, 10)) |_| true else |_| false,
        .float => if (std.fmt.parseFloat(f64, text)) |_| true else |_| false,
        .string => text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"',
        .packed_string_array => std.mem.startsWith(u8, text, "PackedStringArray("),
        .color => std.mem.startsWith(u8, text, "Color("),
        .dictionary => text.len > 0 and text[0] == '{',
        .array => text.len > 0 and text[0] == '[',
        .other => blk: {
            var parsed = parse_mod.parsePropertyValue(arena, text) catch break :blk false;
            parsed.deinit(arena);
            break :blk true;
        },
    };
}

// ---------------------------------------------------------------------------
// Tests

fn fixture(arena: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, arena, .unlimited);
}

fn noFiles(_: *anyopaque, _: []const u8) bool {
    return false;
}

fn everyFile(_: *anyopaque, _: []const u8) bool {
    return true;
}

test "bare presets for every platform come out as the editor's own save, both files, byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    for (export_options.tables) |table| {
        const dir = try std.fmt.allocPrint(arena, "test_fixtures/export/godot_{s}", .{try std.mem.replaceOwned(u8, arena, table.minor, ".", "_")});
        var presets = try load(arena, null, null);
        var intent_text: std.ArrayList(u8) = .empty;
        try intent_text.appendSlice(arena, "{\"presets\": [");
        for (table.platforms, 0..) |platform, i| {
            if (i > 0) try intent_text.appendSlice(arena, ", ");
            try intent_text.print(arena, "{{\"name\": \"{s}\", \"platform\": \"{s}\"}}", .{ platform.name, platform.name });
        }
        try intent_text.appendSlice(arena, "]}");
        const intent = try std.json.parseFromSliceLeaky(std.json.Value, arena, intent_text.items, .{});
        var refusal: Refusal = .{};
        _ = try apply(arena, &presets, table, intent, &refusal);
        const rendered = try render(arena, &presets, table);
        try std.testing.expectEqualStrings(try fixture(arena, try std.fmt.allocPrint(arena, "{s}/export_presets.cfg", .{dir})), rendered.presets);
        try std.testing.expectEqualStrings(try fixture(arena, try std.fmt.allocPrint(arena, "{s}/export_credentials.cfg", .{dir})), rendered.credentials);

        // And the editor's save, read back and written again, is unchanged.
        var reloaded = try load(arena, rendered.presets, rendered.credentials);
        const again = try render(arena, &reloaded, table);
        try std.testing.expectEqualStrings(rendered.presets, again.presets);
        try std.testing.expectEqualStrings(rendered.credentials, again.credentials);
        // The editor's own presets are clean, but for the empty output path
        // a bare preset has.
        for (try validate(arena, &reloaded, table, everyFile, undefined)) |issue| {
            try std.testing.expectEqualStrings("no_export_path", issue.kind);
        }
    }
}

test "a minimal preset is filled in, values are typed by the option, and a secret goes to the credentials file" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = export_options.latest;
    var presets = try load(arena, "[preset.0]\n\nname=\"Linux\"\nplatform=\"Linux\"\nexport_filter=\"all_resources\"\nexport_path=\"build/game.x86_64\"\n", null);
    const intent = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"presets": [
        \\  {"name": "Linux", "runnable": true, "options": {"binary_format/embed_pck": true, "binary_format/architecture": "arm64"}, "custom_features": ["demo", "steam"]},
        \\  {"name": "Android", "platform": "android", "export_path": "build/game.aab", "options": {"gradle_build/export_format": "AAB", "keystore/release_password": "hunter2", "version/code": 3}}
        \\]}
    , .{});
    var refusal: Refusal = .{};
    const applied = try apply(arena, &presets, table, intent, &refusal);
    try std.testing.expectEqual(@as(usize, 1), applied.created.items.len);
    try std.testing.expectEqual(@as(usize, 1), applied.updated.items.len);
    try std.testing.expectEqualStrings("Android: keystore/release_password", applied.secrets.items[0]);

    const rendered = try render(arena, &presets, table);
    try std.testing.expect(std.mem.startsWith(u8, rendered.presets, "[runnable_presets]\n\nLinux=\"Linux\"\n\n[preset.0]\n\nname=\"Linux\"\nplatform=\"Linux\"\ndedicated_server=false\ncustom_features=\"demo, steam\"\n"));
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "export_path=\"build/game.x86_64\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "binary_format/embed_pck=true\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "binary_format/architecture=\"arm64\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "gradle_build/export_format=1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "version/code=3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.credentials, "keystore/release_password=\"hunter2\"\n") != null);
}

test "a wrong value, an unknown option, and a platform Godot would drop are refused with the way out" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = export_options.latest;
    const cases = [_]struct { intent: []const u8, kind: []const u8, hint: []const u8 }{
        .{ .intent = "{\"presets\": [{\"name\": \"W\", \"platform\": \"Windows\", \"options\": {\"binary_format/embed_pk\": true}}]}", .kind = "unknown_option", .hint = "did you mean binary_format/embed_pck" },
        .{ .intent = "{\"presets\": [{\"name\": \"W\", \"platform\": \"Switch\"}]}", .kind = "unknown_platform", .hint = "Windows Desktop" },
        .{ .intent = "{\"presets\": [{\"name\": \"W\", \"platform\": \"Linux\", \"options\": {\"binary_format/architecture\": \"sparc\"}}]}", .kind = "invalid_value", .hint = "x86_64" },
        .{ .intent = "{\"presets\": [{\"name\": \"W\", \"platform\": \"Linux\", \"options\": {\"binary_format/embed_pck\": \"yes\"}}]}", .kind = "invalid_value", .hint = "true or false" },
        .{ .intent = "{\"presets\": [{\"name\": \"W\"}]}", .kind = "invalid_intent", .hint = "creating one needs a platform" },
        .{ .intent = "{\"presets\": [{\"name\": \"W\", \"platform\": \"Linux\", \"embed_pck\": true}]}", .kind = "unknown_field", .hint = "Platform settings go under options" },
    };
    for (cases) |case| {
        var presets = try load(arena, null, null);
        const intent = try std.json.parseFromSliceLeaky(std.json.Value, arena, case.intent, .{});
        var refusal: Refusal = .{};
        try std.testing.expectError(error.InvalidIntent, apply(arena, &presets, table, intent, &refusal));
        try std.testing.expectEqualStrings(case.kind, refusal.kind);
        if (std.mem.indexOf(u8, refusal.hint, case.hint) == null) {
            std.debug.print("hint for {s}: {s}\n", .{ case.intent, refusal.hint });
            return error.TestUnexpectedResult;
        }
    }
}

test "validate names what Godot would silently drop" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const text =
        \\[runnable_presets]
        \\
        \\Linux="Gone"
        \\
        \\[preset.0]
        \\
        \\name="Win"
        \\platform="Windows"
        \\export_filter="all_resources"
        \\include_filter=""
        \\exclude_filter=""
        \\export_path="build/w.exe"
        \\
        \\[preset.2]
        \\
        \\name="Orphan"
        \\platform="Linux"
        \\
    ;
    const presets = try load(arena, text, null);
    const issues = try validate(arena, &presets, export_options.latest, noFiles, undefined);
    var kinds: std.ArrayList(u8) = .empty;
    for (issues) |issue| try kinds.print(arena, "{s} ", .{issue.kind});
    // The preset past the gap is read and checked like any other, and the
    // one with a wrong platform still has its export path checked.
    try std.testing.expectEqualStrings("preset_numbering_gap unknown_platform export_path_not_ignored missing_preset_key missing_preset_key no_export_path runnable_preset_missing ", kinds.items);
    try std.testing.expect(std.mem.indexOf(u8, issues[1].message, "\"Windows Desktop\"") != null);
}

test "an AAB without a Gradle build, a build folder Godot would import, and a missing keystore are flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = export_options.latest;
    var presets = try load(arena, null, null);
    const intent = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"presets": [{"name": "Android", "platform": "Android", "export_path": "build/android/game.aab",
        \\  "options": {"gradle_build/export_format": "AAB", "keystore/release": "/nowhere/release.keystore"}}]}
    , .{});
    var refusal: Refusal = .{};
    _ = try apply(arena, &presets, table, intent, &refusal);
    const rendered = try render(arena, &presets, table);
    const reloaded = try load(arena, rendered.presets, rendered.credentials);
    const issues = try validate(arena, &reloaded, table, noFiles, undefined);
    var kinds: std.ArrayList(u8) = .empty;
    for (issues) |issue| try kinds.print(arena, "{s} ", .{issue.kind});
    try std.testing.expectEqualStrings("export_path_not_ignored missing_file needs_gradle_build ", kinds.items);
    try std.testing.expect(std.mem.indexOf(u8, issues[1].message, "/nowhere") == null);
    try std.testing.expectEqualStrings("build", buildFolderInProject("build/android/game.aab").?);
    try std.testing.expect(buildFolderInProject("/tmp/game.aab") == null);
    try std.testing.expect(buildFolderInProject("../out/game.aab") == null);
}

test "a hand-written file is repaired without losing a preset: the gap closed, the platform corrected, the secret moved" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const table = export_options.latest;
    const text =
        \\[preset.0]
        \\
        \\name="Windows"
        \\platform="Windows"
        \\runnable=true
        \\export_path="build/w.exe"
        \\
        \\[preset.0.options]
        \\
        \\application/company_name="Unabated"
        \\
        \\[preset.1]
        \\
        \\name="Android"
        \\platform="Android"
        \\
        \\[preset.1.options]
        \\
        \\keystore/release_password="hunter2"
        \\
        \\[preset.3]
        \\
        \\name="Linux"
        \\platform="Linux"
        \\
        \\[preset.3.options]
        \\
        \\binary_format/embed_pck=true
        \\
    ;
    var presets = try load(arena, text, null);
    try std.testing.expectEqual(@as(usize, 3), presets.presets.items.len);

    // Options on a preset Godot cannot match are refused until the platform
    // is corrected in the same entry.
    var refusal: Refusal = .{};
    const blocked = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"presets\": [{\"name\": \"Windows\", \"options\": {\"binary_format/embed_pck\": true}}]}", .{});
    try std.testing.expectError(error.InvalidIntent, apply(arena, &presets, table, blocked, &refusal));
    try std.testing.expect(std.mem.indexOf(u8, refusal.hint, "\"Windows Desktop\"") != null);

    presets = try load(arena, text, null);
    const fix = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"presets\": [{\"name\": \"Windows\", \"platform\": \"Windows Desktop\"}]}", .{});
    _ = try apply(arena, &presets, table, fix, &refusal);
    const rendered = try render(arena, &presets, table);
    try std.testing.expect(std.mem.startsWith(u8, rendered.presets, "[runnable_presets]\n\n\"Windows Desktop\"=\"Windows\"\n"));
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "[preset.2]\n\nname=\"Linux\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "application/company_name=\"Unabated\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "hunter2") == null);
    try std.testing.expect(std.mem.indexOf(u8, rendered.credentials, "keystore/release_password=\"hunter2\"") != null);
    const reloaded = try load(arena, rendered.presets, rendered.credentials);
    for (try validate(arena, &reloaded, table, everyFile, undefined)) |issue| {
        try std.testing.expect(issue.severity == .warning);
    }
}

test "a legacy runnable flag and Linux/X11 are read the way load_config reads them" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const presets = try load(arena, "[preset.0]\n\nname=\"L\"\nplatform=\"Linux/X11\"\nrunnable=true\n", null);
    const rendered = try render(arena, &presets, export_options.latest);
    try std.testing.expect(std.mem.startsWith(u8, rendered.presets, "[runnable_presets]\n\nLinux=\"L\"\n\n[preset.0]\n\nname=\"L\"\nplatform=\"Linux\"\n"));
    try std.testing.expect(std.mem.indexOf(u8, rendered.presets, "runnable=") == null);
}
