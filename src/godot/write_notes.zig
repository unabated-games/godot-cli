//! Notes a scene write raises about what it wrote, for the result's messages.
//!
//! Writes happen deep inside handlers that each build their own result, so,
//! as with error_details, the code that sees the problem records it here and
//! the dispatcher adds it to whatever result comes back.

const std = @import("std");

threadlocal var pending: std.ArrayList([]const u8) = .empty;
threadlocal var pending_allocator: ?std.mem.Allocator = null;

/// Forget earlier notes; called before each handler runs.
pub fn reset() void {
    pending = .empty;
    pending_allocator = null;
}

pub fn add(allocator: std.mem.Allocator, note: []const u8) !void {
    if (pending_allocator == null) pending_allocator = allocator;
    for (pending.items) |seen| if (std.mem.eql(u8, seen, note)) return;
    try pending.append(pending_allocator.?, note);
}

/// The notes recorded since the last reset, cleared.
pub fn take() []const []const u8 {
    const items = pending.items;
    pending = .empty;
    pending_allocator = null;
    return items;
}
