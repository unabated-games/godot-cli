//! Search project catalog entries and builtins by tags and free text.

const std = @import("std");
const catalog_scan = @import("catalog_scan.zig");
const catalog_builtins = @import("catalog_builtins.zig");
const uid_cache = @import("uid_cache.zig");

pub const SearchHit = struct {
    id: []const u8,
    source: []const u8,
    summary: []const u8 = "",
    tags: []const []const u8 = &.{},
    score: usize = 0,

    pub fn deinit(self: *const SearchHit, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.source);
        allocator.free(self.summary);
        for (self.tags) |tag| allocator.free(tag);
        allocator.free(self.tags);
    }
};

pub const SearchResult = struct {
    query: []const u8 = "",
    tags: []const []const u8 = &.{},
    hits: []SearchHit = &.{},

    pub fn deinit(self: *SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.query);
        for (self.tags) |tag| allocator.free(tag);
        allocator.free(self.tags);
        for (self.hits) |*hit| hit.deinit(allocator);
        allocator.free(self.hits);
    }
};

pub const SearchError = error{
    OutOfMemory,
    ProjectRootRequired,
    InvalidProjectRoot,
    InvalidBuiltinCatalog,
    Io,
};

pub fn searchCatalog(
    allocator: std.mem.Allocator,
    io: std.Io,
    project_root: ?[]const u8,
    tag_filter: []const []const u8,
    query: []const u8,
) SearchError!SearchResult {
    var hits: std.ArrayList(SearchHit) = .empty;
    errdefer {
        for (hits.items) |*hit| hit.deinit(allocator);
        hits.deinit(allocator);
    }

    const builtins = try catalog_builtins.allEntries(allocator);
    defer catalog_builtins.freeEntries(allocator, builtins);

    for (builtins) |entry| {
        if (!matchesTags(entry.tags, tag_filter)) continue;
        const score = scoreBuiltinText(entry, query);
        if (query.len > 0 and score == 0) continue;
        try hits.append(allocator, try hitFromBuiltin(allocator, entry, score));
    }

    if (project_root) |root| {
        var scan = try catalog_scan.scanProject(allocator, io, root);
        defer scan.deinit(allocator);
        for (scan.entries) |*entry| {
            if (!entry.valid) continue;
            if (!matchesTags(entry.tags, tag_filter)) continue;
            const score = scoreManifestText(entry, query);
            if (query.len > 0 and score == 0) continue;
            try hits.append(allocator, try hitFromManifest(allocator, entry, score));
        }
    }

    std.mem.sort(SearchHit, hits.items, {}, compareHits);

    var owned_tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (owned_tags.items) |tag| allocator.free(tag);
        owned_tags.deinit(allocator);
    }
    for (tag_filter) |tag| try owned_tags.append(allocator, try allocator.dupe(u8, tag));

    return .{
        .query = try allocator.dupe(u8, query),
        .tags = try owned_tags.toOwnedSlice(allocator),
        .hits = try hits.toOwnedSlice(allocator),
    };
}

fn compareHits(_: void, a: SearchHit, b: SearchHit) bool {
    if (a.score != b.score) return a.score > b.score;
    return std.mem.order(u8, a.id, b.id) == .lt;
}

fn matchesTags(entry_tags: []const []const u8, required: []const []const u8) bool {
    if (required.len == 0) return true;
    for (required) |needed| {
        var found = false;
        for (entry_tags) |tag| {
            if (std.ascii.eqlIgnoreCase(tag, needed)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn scoreBuiltinText(entry: catalog_builtins.BuiltinEntry, query: []const u8) usize {
    if (query.len == 0) return 1;
    var score: usize = 0;
    score += scoreText(entry.id, query);
    score += scoreText(entry.class_name, query);
    score += scoreText(entry.summary, query);
    score += scoreText(entry.when_to_use, query);
    score += scoreText(entry.when_not_to_use, query);
    for (entry.tags) |tag| score += scoreText(tag, query);
    for (entry.signals) |signal_doc| {
        score += scoreText(signal_doc.name, query);
        score += scoreText(signal_doc.doc, query);
    }
    return score;
}

fn scoreManifestText(entry: *const catalog_scan.ManifestEntry, query: []const u8) usize {
    if (query.len == 0) return 1;
    var score: usize = 0;
    score += scoreText(entry.id, query);
    score += scoreText(entry.summary, query);
    score += scoreText(entry.when_to_use, query);
    score += scoreText(entry.when_not_to_use, query);
    score += scoreText(entry.notes, query);
    for (entry.tags) |tag| score += scoreText(tag, query);
    for (entry.signal_docs) |row| {
        score += scoreText(row.name, query);
        score += scoreText(row.doc, query);
        score += scoreText(row.connect_example, query);
    }
    for (entry.function_docs) |row| {
        score += scoreText(row.name, query);
        score += scoreText(row.doc, query);
        score += scoreText(row.when_to_call, query);
    }
    return score;
}

fn scoreText(haystack: []const u8, needle: []const u8) usize {
    if (haystack.len == 0 or needle.len == 0) return 0;
    if (std.ascii.indexOfIgnoreCase(haystack, needle) != null) return 2;
    var score: usize = 0;
    var tokens = std.mem.tokenizeAny(u8, needle, " \t");
    while (tokens.next()) |token| {
        if (token.len == 0) continue;
        if (std.ascii.indexOfIgnoreCase(haystack, token) != null) score += 1;
    }
    return score;
}

fn hitFromBuiltin(allocator: std.mem.Allocator, entry: catalog_builtins.BuiltinEntry, score: usize) SearchError!SearchHit {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tags.items) |tag| allocator.free(tag);
        tags.deinit(allocator);
    }
    for (entry.tags) |tag| try tags.append(allocator, try allocator.dupe(u8, tag));
    return .{
        .id = try allocator.dupe(u8, entry.id),
        .source = try allocator.dupe(u8, "builtin"),
        .summary = try allocator.dupe(u8, entry.summary),
        .tags = try tags.toOwnedSlice(allocator),
        .score = score,
    };
}

fn hitFromManifest(allocator: std.mem.Allocator, entry: *const catalog_scan.ManifestEntry, score: usize) SearchError!SearchHit {
    var tags: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (tags.items) |tag| allocator.free(tag);
        tags.deinit(allocator);
    }
    for (entry.tags) |tag| try tags.append(allocator, try allocator.dupe(u8, tag));
    return .{
        .id = try allocator.dupe(u8, entry.id),
        .source = try allocator.dupe(u8, "project"),
        .summary = try allocator.dupe(u8, entry.summary),
        .tags = try tags.toOwnedSlice(allocator),
        .score = score,
    };
}

test "search by tag and query" {
    const allocator = std.testing.allocator;
    var result = try searchCatalog(allocator, std.testing.io, "test_fixtures/project", &.{}, "button");
    defer result.deinit(allocator);
    try std.testing.expect(result.hits.len >= 1);
}
