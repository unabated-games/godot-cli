//! The Godot editor's own settings file, read for what an export needs from
//! this machine rather than the project: the Java and Android SDKs and the
//! debug keystore. `EditorSettings::get_existing_settings_path` and
//! `OS::get_config_path` in the engine are the source for where it lives.

const std = @import("std");
const builtin = @import("builtin");
const lex = @import("variant/lex.zig");

/// The folder Godot keeps editor settings in: `~/Library/Application
/// Support/Godot` on macOS, `$XDG_CONFIG_HOME/godot` (or `~/.config/godot`)
/// on Linux, `%APPDATA%\Godot` on Windows.
pub fn configDir(allocator: std.mem.Allocator, environ: std.process.Environ) ?[]const u8 {
    switch (builtin.os.tag) {
        .macos => {
            const home = environ.getAlloc(allocator, "HOME") catch return null;
            return std.fs.path.join(allocator, &.{ home, "Library", "Application Support", "Godot" }) catch null;
        },
        .windows => {
            const appdata = environ.getAlloc(allocator, "APPDATA") catch return null;
            return std.fs.path.join(allocator, &.{ appdata, "Godot" }) catch null;
        },
        else => {
            if (environ.getAlloc(allocator, "XDG_CONFIG_HOME")) |xdg| {
                if (std.fs.path.isAbsolute(xdg)) return std.fs.path.join(allocator, &.{ xdg, "godot" }) catch null;
            } else |_| {}
            const home = environ.getAlloc(allocator, "HOME") catch return null;
            return std.fs.path.join(allocator, &.{ home, ".config", "godot" }) catch null;
        },
    }
}

/// The folder Godot keeps export templates in, one subfolder per exact
/// version: the data path's `export_templates` (`EditorPaths`): beside the
/// settings on macOS and Windows, `$XDG_DATA_HOME/godot` (or
/// `~/.local/share/godot`) on Linux.
pub fn templatesDir(allocator: std.mem.Allocator, environ: std.process.Environ) ?[]const u8 {
    const data = switch (builtin.os.tag) {
        .macos, .windows => configDir(allocator, environ) orelse return null,
        else => blk: {
            if (environ.getAlloc(allocator, "XDG_DATA_HOME")) |xdg| {
                if (std.fs.path.isAbsolute(xdg)) break :blk std.fs.path.join(allocator, &.{ xdg, "godot" }) catch return null;
            } else |_| {}
            const home = environ.getAlloc(allocator, "HOME") catch return null;
            break :blk std.fs.path.join(allocator, &.{ home, ".local", "share", "godot" }) catch return null;
        },
    };
    return std.fs.path.join(allocator, &.{ data, "export_templates" }) catch null;
}

/// The templates folder name for a `godot --version` line: the version and
/// status, "4.8.beta1" from "4.8.beta1.official.4d10419ca", "4.7.2.stable"
/// from "4.7.2.stable.official.ed1daf0bf" (GODOT_VERSION_FULL_CONFIG).
pub fn templatesVersion(version_line: []const u8) ?[]const u8 {
    var end: usize = 0;
    var parts = std.mem.splitScalar(u8, std.mem.trim(u8, version_line, " \t\r\n"), '.');
    while (parts.next()) |part| {
        end += part.len + @intFromBool(end > 0);
        const status = for ([_][]const u8{ "stable", "dev", "alpha", "beta", "rc" }) |prefix| {
            if (std.mem.startsWith(u8, part, prefix)) break true;
        } else false;
        if (status) return std.mem.trim(u8, version_line, " \t\r\n")[0..end];
    }
    return null;
}

test "the templates folder is named by version and status" {
    try std.testing.expectEqualStrings("4.8.beta1", templatesVersion("4.8.beta1.official.4d10419ca\n").?);
    try std.testing.expectEqualStrings("4.7.2.stable", templatesVersion("4.7.2.stable.official.ed1daf0bf").?);
    try std.testing.expectEqualStrings("4.7.stable", templatesVersion("4.7.stable.official.5b4e0cb0f").?);
    try std.testing.expect(templatesVersion("nonsense") == null);
}

/// The settings file an editor of `minor` ("4.8") reads: its own version's,
/// or the newest older one, as the editor itself falls back. With no minor,
/// the newest file there is.
pub fn findFile(allocator: std.mem.Allocator, io: std.Io, environ: std.process.Environ, minor: ?[]const u8) ?[]const u8 {
    const dir = configDir(allocator, environ) orelse return null;
    var start: u32 = 20;
    if (minor) |text| {
        if (std.mem.indexOfScalar(u8, text, '.')) |dot| {
            start = std.fmt.parseInt(u32, text[dot + 1 ..], 10) catch 20;
        }
    }
    var m: i64 = start;
    while (m >= 3) : (m -= 1) {
        const name = allocator.print("editor_settings-4.{d}.tres", .{m}) catch return null;
        const path = std.fs.path.join(allocator, &.{ dir, name }) catch return null;
        if (std.Io.Dir.cwd().access(io, path, .{})) |_| return path else |_| {}
    }
    const legacy = std.fs.path.join(allocator, &.{ dir, "editor_settings-4.tres" }) catch return null;
    if (std.Io.Dir.cwd().access(io, legacy, .{})) |_| return legacy else |_| {}
    return null;
}

/// A string setting's value, unquoted, or null when the file does not set it.
pub fn stringValue(allocator: std.mem.Allocator, text: []const u8, key: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, trimmed, key)) continue;
        const rest = std.mem.trimStart(u8, trimmed[key.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        const value = std.mem.trim(u8, rest[1..], " \t");
        if (value.len < 2 or value[0] != '"') return null;
        return lex.parseQuotedString(allocator, value) catch null;
    }
    return null;
}

test "a string setting is read and unquoted" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const text =
        \\[resource]
        \\export/android/debug_keystore = "/Users/a/debug.keystore"
        \\export/android/java_sdk_path = ""
        \\export/android/android_sdk_path_extra = "no"
        \\
    ;
    try std.testing.expectEqualStrings("/Users/a/debug.keystore", stringValue(arena.allocator(), text, "export/android/debug_keystore").?);
    try std.testing.expectEqualStrings("", stringValue(arena.allocator(), text, "export/android/java_sdk_path").?);
    try std.testing.expect(stringValue(arena.allocator(), text, "export/android/android_sdk_path") == null);
}
