const std = @import("std");
const spec = @import("spec.zig");
const version = @import("../version.zig");

pub fn printRootHelp(
    writer: *std.Io.Writer,
    root: *const spec.CommandSpec,
) std.Io.Writer.Error!void {
    try writer.print("{s} — {s}\n\n", .{ version.name, version.summary });
    try writer.print("Usage:\n", .{});
    try writer.print("  {s} [global options] <command> [command options] [args...]\n", .{version.name});
    try writer.print("  {s} --request <json>\n", .{version.name});
    try writer.print("  {s} --request-file <path>\n", .{version.name});
    try writer.print("  {s} --request-stdin\n\n", .{version.name});

    try writer.print("Global options:\n", .{});
    try printGlobalOptions(writer);
    try writer.print("\nCommands:\n", .{});
    for (root.children) |child| {
        try writer.print("  {s:<16} {s}\n", .{ child.name, child.summary });
    }
    try writer.print("\nRun '{s} help <command>' for command-specific help.\n", .{version.name});
}

pub fn printCommandHelp(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    root: *const spec.CommandSpec,
    path: []const []const u8,
) (std.Io.Writer.Error || spec.CliError)!void {
    const command = findCommand(root, path) orelse return error.UnknownCommand;

    var usage: std.ArrayList(u8) = .empty;
    defer usage.deinit(allocator);

    try usage.appendSlice(allocator, version.name);
    for (path) |segment| {
        try usage.append(allocator, ' ');
        try usage.appendSlice(allocator, segment);
    }
    if (command.options.len != 0 or command.children.len != 0) {
        try usage.appendSlice(allocator, " [options]");
    }
    for (command.positionals) |arg| {
        try usage.append(allocator, ' ');
        try appendPositionalUsage(&usage, allocator, arg);
    }

    try writer.print("{s}\n\n", .{usage.items});
    try writer.print("{s}\n\n", .{command.summary});
    if (command.description) |description| {
        try writer.print("{s}\n\n", .{description});
    }

    if (command.positionals.len != 0) {
        try writer.print("Arguments:\n", .{});
        for (command.positionals) |arg| {
            var label: [64]u8 = undefined;
            const label_text = std.fmt.bufPrint(&label, "<{s}>{s}", .{ arg.name, if (arg.variadic) "..." else "" }) catch arg.name;
            try writer.print("  {s:<30} {s}{s}\n", .{ label_text, arg.description, if (arg.required) "" else " (optional)" });
        }
        try writer.print("\n", .{});
    }

    if (command.options.len != 0) {
        try writer.print("Options:\n", .{});
        for (command.options) |opt| {
            try printOption(writer, opt);
        }
        try writer.print("\n", .{});
    }

    if (command.children.len != 0) {
        try writer.print("Subcommands:\n", .{});
        for (command.children) |child| {
            try writer.print("  {s:<16} {s}\n", .{ child.name, child.summary });
        }
        try writer.print("\n", .{});
    }
}

/// `<file>`, `[node]`, or `<files>...`: the same spelling the man page and
/// the Markdown reference use.
pub fn appendPositionalUsage(out: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: spec.PositionalSpec) !void {
    try out.append(allocator, if (arg.required) '<' else '[');
    try out.appendSlice(allocator, arg.name);
    try out.append(allocator, if (arg.required) '>' else ']');
    if (arg.variadic) try out.appendSlice(allocator, "...");
}

fn printGlobalOptions(writer: *std.Io.Writer) std.Io.Writer.Error!void {
    // Same table the man page and completions render, so the three cannot
    // disagree about which global options exist.
    for (spec.global_options) |opt| {
        try printOption(writer, .{
            .long = opt.long,
            .short = opt.short,
            .kind = opt.kind,
            .description = opt.description,
        });
    }
}

fn printOption(writer: *std.Io.Writer, opt: spec.OptionSpec) std.Io.Writer.Error!void {
    const placeholder = switch (opt.kind) {
        .flag => "",
        .string => " <value>",
        .path => " <path>",
    };

    // Pad the whole label — flag, short form, and value placeholder together —
    // so descriptions line up in a column. Padding only the placeholder left
    // every line starting at a different offset.
    var label: [64]u8 = undefined;
    // An option name too long for the buffer degrades to the bare long form
    // rather than tripping an unreachable — help text is never worth a crash.
    const label_text = if (opt.short) |short_char|
        std.fmt.bufPrint(&label, "-{c}, --{s}{s}", .{ short_char, opt.long, placeholder }) catch opt.long
    else
        std.fmt.bufPrint(&label, "    --{s}{s}", .{ opt.long, placeholder }) catch opt.long;

    try writer.print("  {s:<30} {s}\n", .{ label_text, opt.description });
}

pub fn findCommand(root: *const spec.CommandSpec, path: []const []const u8) ?*const spec.CommandSpec {
    var current: *const spec.CommandSpec = root;
    for (path) |segment| {
        var found: ?*const spec.CommandSpec = null;
        for (current.children, 0..) |child, child_index| {
            if (std.mem.eql(u8, child.name, segment)) {
                found = &current.children[child_index];
                break;
            }
        }
        current = found orelse return null;
    }
    return current;
}
