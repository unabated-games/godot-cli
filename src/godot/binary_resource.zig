//! The header of a Godot binary resource (`.res`, `.scn`): its class and its
//! resource UID. A text resource keeps its UID in the `[gd_resource]` or
//! `[gd_scene]` line; a binary one keeps it in this header, so reading it is
//! the only way to know the UID without the project's `uid_cache.bin`, and a
//! hash of the file's bytes is never it (the bytes contain the UID).
//!
//! Only the header is read. Property data is not parsed.
//!
//! Layout from `core/io/resource_format_binary.cpp` (`ResourceLoaderBinary::open`,
//! `ResourceFormatSaverBinaryInstance::save`) and, for the `RSCC` variant the
//! editor writes by default (`filesystem/on_save/compress_binary_resources`),
//! the block framing in `core/io/file_access_compressed.cpp`.

const std = @import("std");
const resource_uid = @import("resource_uid.zig");

pub const Header = struct {
    /// The resource's class, e.g. `ArrayMesh` or `PackedScene`.
    class_name: []const u8,
    /// Null when the file records no UID: `FORMAT_FLAG_UIDS` unset, as in a
    /// Godot 3 file, or Godot's invalid id, as a script-side save writes.
    uid: ?i64,
    compressed: bool,
    engine_major: u32,
    engine_minor: u32,
    format_version: u32,

    pub fn deinit(self: *Header, allocator: std.mem.Allocator) void {
        allocator.free(self.class_name);
    }
};

pub const Error = error{
    OutOfMemory,
    /// Neither `RSRC` nor `RSCC`: not a binary resource.
    NotBinaryResource,
    /// A binary resource whose header does not parse. Named apart from the
    /// UID cache parser's `Corrupt`, which the CLI reports as the cache.
    CorruptBinaryResource,
    /// `RSCC` with a compression mode other than zstd. Godot's saver always
    /// uses zstd, so this is a file from somewhere else.
    UnsupportedCompression,
    /// A format version newer than this reader knows the layout of.
    UnsupportedVersion,
};

pub const ReadError = Error || error{ FileNotFound, Io };

const magic_plain = "RSRC";
const magic_compressed = "RSCC";

/// `ResourceFormatSaverBinaryInstance::FORMAT_VERSION` as of Godot 4.8. The
/// header layout this reads has been stable since Godot 3's format 3.
const max_format_version = 6;
const format_flag_uids = 2;
/// `Compression::MODE_ZSTD`, the mode `FileAccessCompressed` defaults to.
const compression_mode_zstd = 2;

/// Enough for the fixed fields and any real class name.
const plain_prefix_len = 64 * 1024;
/// `FileAccessCompressed` uses 4096; anything past this is not a Godot file.
const max_block_len = 16 * 1024 * 1024;

pub fn hasMagic(bytes: []const u8) bool {
    return bytes.len >= 4 and (std.mem.eql(u8, bytes[0..4], magic_plain) or std.mem.eql(u8, bytes[0..4], magic_compressed));
}

/// Parse the header from the start of a file. `bytes` may be a prefix, as
/// long as it holds the header (for `RSCC`, through the end of block 0).
pub fn parseHeader(allocator: std.mem.Allocator, bytes: []const u8) Error!Header {
    if (bytes.len < 4) return error.NotBinaryResource;
    if (std.mem.eql(u8, bytes[0..4], magic_plain)) return parseBody(allocator, bytes[4..], false);
    if (!std.mem.eql(u8, bytes[0..4], magic_compressed)) return error.NotBinaryResource;

    const frame = try CompressedFrame.parse(bytes);
    if (bytes.len < frame.block0_end) return error.CorruptBinaryResource;
    const block0 = try decompressZstd(allocator, bytes[frame.block0_start..frame.block0_end], frame.block0_len);
    defer allocator.free(block0);
    return parseBody(allocator, block0, true);
}

/// Read only as much of `path` as the header needs: a binary mesh can run to
/// hundreds of megabytes, and this runs for every reference a scene saves.
pub fn readHeader(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ReadError!Header {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.Io,
    };
    defer file.close(io);

    var start: [CompressedFrame.fixed_len]u8 = undefined;
    const got = file.readPositionalAll(io, &start, 0) catch return error.Io;
    if (!hasMagic(start[0..got])) return error.NotBinaryResource;

    const want: usize = if (std.mem.eql(u8, start[0..4], magic_plain))
        plain_prefix_len
    else blk: {
        if (got < start.len) return error.CorruptBinaryResource;
        // The block table sits between the fixed fields and block 0, so its
        // length decides how far to read.
        var table_head: [4]u8 = undefined;
        const frame = try CompressedFrame.parseFixed(&start);
        if ((file.readPositionalAll(io, &table_head, CompressedFrame.fixed_len) catch return error.Io) < 4) return error.CorruptBinaryResource;
        const block0_csize = std.mem.readInt(u32, &table_head, .little);
        if (block0_csize > max_block_len) return error.CorruptBinaryResource;
        break :blk frame.table_end + block0_csize;
    };

    const buffer = try allocator.alloc(u8, want);
    defer allocator.free(buffer);
    const len = file.readPositionalAll(io, buffer, 0) catch return error.Io;
    return parseHeader(allocator, buffer[0..len]);
}

/// Whether the file at `path` is a binary resource, by its magic. False for
/// anything unreadable.
pub fn isBinaryResourceFile(io: std.Io, path: []const u8) bool {
    const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch return false;
    defer file.close(io);
    var start: [4]u8 = undefined;
    const got = file.readPositionalAll(io, &start, 0) catch return false;
    return hasMagic(start[0..got]);
}

/// `RSCC`, then mode, block size and total length as little-endian u32, then
/// one compressed size per block, then the blocks. Each block is a complete
/// zstd frame of `block_len` bytes, the last one of `total % block_len`.
const CompressedFrame = struct {
    const fixed_len = 16;

    table_end: usize,
    block0_start: usize,
    block0_end: usize,
    block0_len: usize,

    fn parseFixed(bytes: *const [fixed_len]u8) Error!struct { table_end: usize, block_len: u32, total: u32 } {
        const mode = std.mem.readInt(u32, bytes[4..8], .little);
        if (mode != compression_mode_zstd) return error.UnsupportedCompression;
        const block_len = std.mem.readInt(u32, bytes[8..12], .little);
        if (block_len == 0 or block_len > max_block_len) return error.CorruptBinaryResource;
        const total = std.mem.readInt(u32, bytes[12..16], .little);
        const block_count: usize = @as(usize, total / block_len) + 1;
        return .{ .table_end = fixed_len + block_count * 4, .block_len = block_len, .total = total };
    }

    fn parse(bytes: []const u8) Error!CompressedFrame {
        if (bytes.len < fixed_len + 4) return error.CorruptBinaryResource;
        const fixed = try parseFixed(bytes[0..fixed_len]);
        const csize = std.mem.readInt(u32, bytes[fixed_len..][0..4], .little);
        if (csize > max_block_len) return error.CorruptBinaryResource;
        // `open_after_magic`: a single block holds the whole stream.
        const single = fixed.table_end == fixed_len + 4;
        return .{
            .table_end = fixed.table_end,
            .block0_start = fixed.table_end,
            .block0_end = fixed.table_end + csize,
            .block0_len = if (single) fixed.total else fixed.block_len,
        };
    }
};

fn decompressZstd(allocator: std.mem.Allocator, compressed: []const u8, expected_len: usize) Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var in: std.Io.Reader = .fixed(compressed);
    var stream: std.compress.zstd.Decompress = .init(&in, &.{}, .{});
    _ = stream.reader.streamRemaining(&out.writer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => return error.CorruptBinaryResource,
    };
    if (out.written().len != expected_len) return error.CorruptBinaryResource;
    return out.toOwnedSlice() catch return error.OutOfMemory;
}

/// Everything after the magic, which in `RSCC` is the start of the
/// decompressed stream (the compressed form has no inner `RSRC`).
fn parseBody(allocator: std.mem.Allocator, body: []const u8, compressed: bool) Error!Header {
    var cursor: Cursor = .{ .bytes = body };
    // These two are written before the saver switches endianness.
    const big_endian = (try cursor.readU32()) != 0;
    _ = try cursor.readU32(); // "64 bits file", always 0
    cursor.big_endian = big_endian;

    const engine_major = try cursor.readU32();
    const engine_minor = try cursor.readU32();
    const format_version = try cursor.readU32();
    if (format_version > max_format_version) return error.UnsupportedVersion;

    // `save_unicode_string`: a length that counts the NUL, then the bytes.
    const class_len = try cursor.readU32();
    const class_bytes = try cursor.take(class_len);
    const class_name = std.mem.trimEnd(u8, class_bytes, "\x00");

    _ = try cursor.readU64(); // offset to import metadata
    const flags = try cursor.readU32();
    // The UID slot is always present; Godot 3 wrote reserved zeros there.
    const raw_uid: i64 = @bitCast(try cursor.readU64());
    const uid: ?i64 = if (flags & format_flag_uids != 0 and raw_uid != resource_uid.invalid_id) raw_uid else null;

    return .{
        .class_name = try allocator.dupe(u8, class_name),
        .uid = uid,
        .compressed = compressed,
        .engine_major = engine_major,
        .engine_minor = engine_minor,
        .format_version = format_version,
    };
}

const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,
    big_endian: bool = false,

    fn take(self: *Cursor, n: usize) Error![]const u8 {
        if (n > self.bytes.len - self.pos) return error.CorruptBinaryResource;
        const slice = self.bytes[self.pos .. self.pos + n];
        self.pos += n;
        return slice;
    }

    fn readU32(self: *Cursor) Error!u32 {
        const b = try self.take(4);
        return std.mem.readInt(u32, b[0..4], if (self.big_endian) .big else .little);
    }

    fn readU64(self: *Cursor) Error!u64 {
        const b = try self.take(8);
        return std.mem.readInt(u64, b[0..8], if (self.big_endian) .big else .little);
    }
};

// The fixtures are files Godot 4.8 saved; the expected UIDs and classes are
// what `ResourceLoader.get_resource_uid` and `load()` report for them after an
// editor import. Outside the editor that call only consults the uid cache, so
// it reports no UID for a file the editor has not scanned since it changed.

fn expectFixture(path: []const u8, class_name: []const u8, uid_text: ?[]const u8, compressed: bool) !void {
    const allocator = std.testing.allocator;
    var header = try readHeader(allocator, std.testing.io, path);
    defer header.deinit(allocator);
    try std.testing.expectEqualStrings(class_name, header.class_name);
    try std.testing.expectEqual(compressed, header.compressed);
    try std.testing.expectEqual(@as(u32, 4), header.engine_major);
    if (uid_text) |text| {
        try std.testing.expectEqual(resource_uid.textToId(text), header.uid.?);
    } else {
        try std.testing.expectEqual(@as(?i64, null), header.uid);
    }
}

test "uncompressed binary resource: class and uid from the header" {
    try expectFixture("test_fixtures/project/resources/mesh_godot_saved.res", "BoxMesh", "uid://bc628hhe4x5yp", false);
}

test "compressed binary resource, the editor's default: uid from block 0" {
    try expectFixture("test_fixtures/project/resources/mesh_compressed_godot_saved.res", "SphereMesh", "uid://ci8fbl838ce7m", true);
}

test "compressed binary resource spanning blocks: block 0 found past the table" {
    try expectFixture("test_fixtures/project/resources/mesh_multiblock_godot_saved.res", "ArrayMesh", "uid://dcx3lbfhkywbk", true);
}

test "a binary resource saved without a uid reports none" {
    try expectFixture("test_fixtures/project/resources/mesh_no_uid_godot_saved.res", "CapsuleMesh", null, false);
}

test "a text resource is not a binary resource" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.NotBinaryResource, readHeader(allocator, std.testing.io, "test_fixtures/project/sample_material.tres"));
    try std.testing.expect(!isBinaryResourceFile(std.testing.io, "test_fixtures/project/sample_material.tres"));
    try std.testing.expect(isBinaryResourceFile(std.testing.io, "test_fixtures/project/resources/mesh_godot_saved.res"));
}

test "truncated and foreign headers are reported, not read past" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.CorruptBinaryResource, parseHeader(allocator, "RSRC\x00\x00\x00\x00"));
    try std.testing.expectError(error.CorruptBinaryResource, parseHeader(allocator, "RSCC\x02\x00\x00\x00"));
    // Deflate-framed RSCC: not something Godot's saver writes.
    try std.testing.expectError(error.UnsupportedCompression, parseHeader(allocator, "RSCC\x01\x00\x00\x00\x00\x10\x00\x00\x10\x00\x00\x00\x00\x00\x00\x00"));
}

test "a big-endian header reads the same" {
    const allocator = std.testing.allocator;
    // FLAG_SAVE_BIG_ENDIAN: the first two fields stay little-endian, the rest flip.
    const bytes = "RSRC" ++ "\x01\x00\x00\x00" ++ "\x00\x00\x00\x00" ++
        "\x00\x00\x00\x04" ++ "\x00\x00\x00\x08" ++ "\x00\x00\x00\x06" ++
        "\x00\x00\x00\x05" ++ "Mesh\x00" ++ "\x00" ** 8 ++ "\x00\x00\x00\x03" ++
        "\x23\xfa\x62\x6b\xa9\x55\x1c\x7f";
    var header = try parseHeader(allocator, bytes);
    defer header.deinit(allocator);
    try std.testing.expectEqualStrings("Mesh", header.class_name);
    try std.testing.expectEqual(@as(u32, 8), header.engine_minor);
    try std.testing.expectEqual(resource_uid.textToId("uid://bc628hhe4x5yp"), header.uid.?);
}
