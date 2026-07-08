//! Structural parser for Godot `.tscn` / `.tres` text files (headers + raw properties).

const std = @import("std");
const tag = @import("tag.zig");

pub const PropertyLine = struct {
    line: usize,
    raw: []const u8,
};

pub const Section = struct {
    line: usize,
    header: tag.Tag,
    properties: std.ArrayList(PropertyLine),

    pub fn deinit(self: *Section, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        for (self.properties.items) |prop| allocator.free(prop.raw);
        self.properties.deinit(allocator);
    }
};

pub const Document = struct {
    sections: std.ArrayList(Section),

    pub fn init(allocator: std.mem.Allocator) Document {
        _ = allocator;
        return .{
            .sections = .empty,
        };
    }

    pub fn deinit(self: *Document, allocator: std.mem.Allocator) void {
        for (self.sections.items) |*section| section.deinit(allocator);
        self.sections.deinit(allocator);
    }
};

pub const ParseError = error{
    Io,
    OutOfMemory,
    InvalidHeader,
    UnexpectedEof,
    InvalidSyntax,
};

pub fn parseBytes(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Document {
    var doc = Document.init(allocator);
    errdefer doc.deinit(allocator);

    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    var current: ?Section = null;

    while (lines.next()) |line| {
        line_no += 1;
        const trimmed = std.mem.trim(u8, line, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;

        if (trimmed[0] == '[') {
            if (current) |section| {
                try doc.sections.append(allocator, section);
            }

            const header = try tag.parseLine(allocator, trimmed);
            current = Section{
                .line = line_no,
                .header = header,
                .properties = .empty,
            };
            continue;
        }

        if (current) |*section| {
            const raw = try allocator.dupe(u8, trimmed);
            try section.properties.append(allocator, .{ .line = line_no, .raw = raw });
        }
    }

    if (current) |section| {
        try doc.sections.append(allocator, section);
    }

    return doc;
}

pub fn parseFile(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ParseError!Document {
    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .unlimited) catch return error.Io;
    defer allocator.free(bytes);
    return parseBytes(allocator, bytes);
}

test "parse sample scene structure" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="Script" path="res://foo.gd" id="1_ldc4g"]
        \\
        \\[node name="Root" type="Node"]
        \\script = ExtResource("1_ldc4g")
        \\
    ;

    var doc = try parseBytes(allocator, source);
    defer doc.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), doc.sections.items.len);
    try std.testing.expectEqualStrings("gd_scene", doc.sections.items[0].header.name);
    try std.testing.expectEqual(@as(usize, 1), doc.sections.items[2].properties.items.len);
}
