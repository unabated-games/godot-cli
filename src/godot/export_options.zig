//! The export option tables, one per Godot minor version, and which one a
//! project gets.
//!
//! Each table is generated from that engine's editor (tools/gen_export_options.sh)
//! because export options are defined in each platform's C++ and appear in no
//! class reference. The editor writes every one of them into
//! export_presets.cfg on each save, so a preset written with the wrong
//! version's list gets rewritten the first time someone opens the project.

const std = @import("std");
pub const types = @import("export_options/types.zig");

pub const tables = [_]*const types.Table{
    &@import("export_options/godot_4_7.zig").table,
    &@import("export_options/godot_4_8.zig").table,
};

pub const latest = tables[tables.len - 1];

/// The table for a project whose `config/features` names `minor` ("4.7"), or
/// the newest one for a version it has none for. A project the editor has
/// never opened carries no version; the newest table is the best guess, and
/// an older editor keeps the extra options rather than failing on them.
pub fn forMinor(minor: ?[]const u8) *const types.Table {
    const wanted = minor orelse return latest;
    for (tables) |table| {
        if (std.mem.eql(u8, table.minor, wanted)) return table;
    }
    return latest;
}

/// The engine version a project's `config/features` value names: the first
/// element that looks like `4.7`.
pub const minorFromFeatures = @import("project_godot.zig").minorFromFeatures;

/// Names people and agents use for a platform that are not what the preset
/// file holds. The file needs the exact `get_name()` text, and a preset naming
/// anything else is skipped when Godot loads the file and dropped when it
/// next saves.
const aliases = [_]struct { alias: []const u8, name: []const u8 }{
    .{ .alias = "windows", .name = "Windows Desktop" },
    .{ .alias = "win", .name = "Windows Desktop" },
    .{ .alias = "linux/x11", .name = "Linux" },
    .{ .alias = "x11", .name = "Linux" },
    .{ .alias = "linuxbsd", .name = "Linux" },
    .{ .alias = "html5", .name = "Web" },
    .{ .alias = "javascript", .name = "Web" },
    .{ .alias = "mac", .name = "macOS" },
    .{ .alias = "macos", .name = "macOS" },
    .{ .alias = "osx", .name = "macOS" },
    .{ .alias = "mac osx", .name = "macOS" },
};

pub fn findPlatform(table: *const types.Table, name: []const u8) ?*const types.Platform {
    for (table.platforms) |*platform| {
        if (std.mem.eql(u8, platform.name, name)) return platform;
    }
    return null;
}

/// `findPlatform`, but forgiving: any case, the OS name, or an old or common
/// alias. The result's `name` is what to write.
pub fn resolvePlatform(table: *const types.Table, name: []const u8) ?*const types.Platform {
    if (findPlatform(table, name)) |platform| return platform;
    for (table.platforms) |*platform| {
        if (std.ascii.eqlIgnoreCase(platform.name, name) or std.ascii.eqlIgnoreCase(platform.os_name, name)) return platform;
    }
    for (aliases) |entry| {
        if (std.ascii.eqlIgnoreCase(entry.alias, name)) return findPlatform(table, entry.name);
    }
    return null;
}

pub fn findOption(platform: *const types.Platform, name: []const u8) ?*const types.Option {
    for (platform.options) |*option| {
        if (std.mem.eql(u8, option.name, name)) return option;
    }
    return null;
}

pub fn findKey(keys: []const types.Key, name: []const u8) ?*const types.Key {
    for (keys) |*key| {
        if (std.mem.eql(u8, key.name, name)) return key;
    }
    return null;
}

/// The closest option name by edit distance, for "did you mean". Only
/// offered when it is close enough to be the likely intent.
pub fn nearestOption(platform: *const types.Platform, name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (platform.options) |option| {
        const distance = editDistance(option.name, name);
        if (distance < best_distance) {
            best_distance = distance;
            best = option.name;
        }
    }
    // A wrong prefix (`application/icon` on a platform that calls it
    // `icons/...`) is a different option, not a typo.
    if (best_distance <= @max(@as(usize, 3), name.len / 5)) return best;
    // Same leaf, different group: `icon` under the wrong prefix.
    const leaf = if (std.mem.lastIndexOfScalar(u8, name, '/')) |slash| name[slash + 1 ..] else name;
    for (platform.options) |option| {
        if (std.mem.endsWith(u8, option.name, leaf) and option.name.len > leaf.len and option.name[option.name.len - leaf.len - 1] == '/') return option.name;
    }
    return null;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 96 or b.len > 96) return std.math.maxInt(usize);
    var previous: [97]usize = undefined;
    var current: [97]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |ca, i| {
        current[0] = i + 1;
        for (b, 0..) |cb, j| {
            const cost: usize = if (std.ascii.toLower(ca) == std.ascii.toLower(cb)) 0 else 1;
            current[j + 1] = @min(@min(previous[j + 1] + 1, current[j] + 1), previous[j] + cost);
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

test "every table covers the seven built-in platforms, and Windows is Windows Desktop" {
    for (tables) |table| {
        try std.testing.expectEqual(@as(usize, 7), table.platforms.len);
        try std.testing.expectEqualStrings("Windows Desktop", resolvePlatform(table, "windows").?.name);
        try std.testing.expectEqualStrings("Web", resolvePlatform(table, "HTML5").?.name);
        try std.testing.expectEqualStrings("macOS", resolvePlatform(table, "macos").?.name);
        try std.testing.expect(resolvePlatform(table, "Switch") == null);
        try std.testing.expect(findOption(resolvePlatform(table, "Android").?, "keystore/release_password").?.secret);
    }
}

test "a project's version picks its table" {
    try std.testing.expectEqualStrings("4.7", minorFromFeatures("PackedStringArray(\"4.7\", \"Forward Plus\")").?);
    try std.testing.expectEqualStrings("4.7", forMinor("4.7").minor);
    try std.testing.expectEqualStrings(latest.minor, forMinor(null).minor);
    try std.testing.expectEqualStrings(latest.minor, forMinor("9.9").minor);
    try std.testing.expect(minorFromFeatures("PackedStringArray(\"Mobile\")") == null);
}

test "a near miss on an option name is suggested" {
    const linux = findPlatform(latest, "Linux").?;
    try std.testing.expectEqualStrings("binary_format/embed_pck", nearestOption(linux, "binary_format/embed_pk").?);
    try std.testing.expectEqualStrings("binary_format/embed_pck", nearestOption(linux, "embed_pck").?);
}
