//! Levenshtein distance, for "did you mean" suggestions.

const std = @import("std");

pub fn distance(a: []const u8, b: []const u8) usize {
    if (a.len == 0) return b.len;
    if (b.len == 0) return a.len;
    // Bounded so the row fits a fixed buffer; names are short, and a
    // pathological argument should not cost more than a wrong answer.
    if (a.len > 64 or b.len > 64) return std.math.maxInt(usize);

    var previous: [65]usize = undefined;
    var current: [65]usize = undefined;
    for (0..b.len + 1) |i| previous[i] = i;

    for (a, 0..) |ca, i| {
        current[0] = i + 1;
        for (b, 0..) |cb, j| {
            const substitute = previous[j] + @intFromBool(ca != cb);
            const insert = current[j] + 1;
            const delete = previous[j + 1] + 1;
            current[j + 1] = @min(substitute, @min(insert, delete));
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// The candidate nearest `name`, when it is near enough to be a typo of it:
/// at most half the name's length away, and never the name itself.
pub fn closest(name: []const u8, candidates: []const []const u8) ?[]const u8 {
    var best: usize = std.math.maxInt(usize);
    var found: ?[]const u8 = null;
    for (candidates) |candidate| {
        const d = distance(name, candidate);
        if (d == 0 or d >= best) continue;
        best = d;
        found = candidate;
    }
    if (found == null or best > @max(name.len, 2) / 2) return null;
    return found;
}

test "closest suggests a near name and nothing for a far one" {
    const names = [_][]const u8{ "max_health", "speed", "jump_height" };
    try std.testing.expectEqualStrings("max_health", closest("max_helth", &names).?);
    try std.testing.expectEqualStrings("speed", closest("sped", &names).?);
    try std.testing.expect(closest("colour", &names) == null);
}
