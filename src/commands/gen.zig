//! Commands that render the CLI's own surface: shell completions, the man
//! page, and the Markdown command reference.
//!
//! Each one is generated from the `CommandSpec` tree in `commands.zig`, so the
//! packaged completions and docs cannot describe a command the binary does not
//! have. `zig build docs` runs these to refresh the committed copies.

const std = @import("std");
const spec = @import("../cli/spec.zig");
const app_mod = @import("../cli/app.zig");
const gen = @import("../cli/gen.zig");
const io_util = @import("../io_util.zig");
const version = @import("../version.zig");

fn appFrom(ctx: *anyopaque) *const app_mod.App {
    return @ptrCast(@alignCast(ctx));
}

/// Either write the generated text to `--output` or hand it back as the single
/// result message. Handlers never write to stdout themselves.
fn emitGenerated(
    cli: *const app_mod.App,
    inv: *const spec.Invocation,
    kind: []const u8,
    text: []const u8,
) !spec.Result {
    if (inv.getOption("output")) |output_path| {
        io_util.writeFileAtomic(cli.io, output_path, text) catch return error.Io;

        var data: std.json.ObjectMap = .{};
        try data.put(cli.allocator, "kind", .{ .string = try cli.allocator.dupe(u8, kind) });
        try data.put(cli.allocator, "path", .{ .string = try cli.allocator.dupe(u8, output_path) });
        try data.put(cli.allocator, "byte_count", .{ .integer = @intCast(text.len) });

        const summary = try std.fmt.allocPrint(cli.allocator, "wrote {s} to {s}", .{ kind, output_path });
        try data.put(cli.allocator, "summary", .{ .string = summary });

        return .{ .data = .{ .object = data } };
    }

    // Messages are printed one per line, so the generated trailing newline
    // would otherwise become a blank line on stdout.
    const trimmed = std.mem.trimEnd(u8, text, "\n");
    const messages = try cli.allocator.alloc([]const u8, 1);
    messages[0] = trimmed;
    return .{ .messages = messages };
}

fn completionsHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);

    if (inv.positionals.len != 1) return error.Usage;
    const shell = gen.Shell.parse(inv.positionals[0]) orelse return error.InvalidValue;

    const text = try gen.completions(cli.allocator, cli.root, version.name, shell);
    return emitGenerated(cli, inv, @tagName(shell), text);
}

fn manHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);

    const text = try gen.manPage(
        cli.allocator,
        cli.root,
        version.name,
        version.summary,
        version.version,
        version.version_date,
    );
    return emitGenerated(cli, inv, "man page", text);
}

fn referenceHandler(ctx: *anyopaque, inv: *const spec.Invocation) !spec.Result {
    const cli = appFrom(ctx);

    const text = try gen.markdown(cli.allocator, cli.root, version.name, version.summary);
    return emitGenerated(cli, inv, "command reference", text);
}

const output_option = spec.OptionSpec{
    .long = "output",
    .kind = .path,
    .description = "Write to this file instead of stdout",
};

pub fn completionsCommand() spec.CommandSpec {
    return .{
        .name = "completions",
        .summary = "Print shell completions (bash, zsh, fish)",
        .description =
        \\Generated from the command tree, so completions stay in step with the
        \\binary that printed them.
        \\
        \\  bash:  godot-cli completions bash > ~/.godot-cli/share/completions/godot-cli.bash
        \\  zsh:   godot-cli completions zsh  > "${fpath[1]}/_godot-cli"
        \\  fish:  godot-cli completions fish > ~/.config/fish/completions/godot-cli.fish
        ,
        .options = &.{output_option},
        .handler = completionsHandler,
    };
}

pub fn manCommand() spec.CommandSpec {
    return .{
        .name = "man",
        .summary = "Print the godot-cli(1) man page in roff format",
        .description =
        \\Render with: godot-cli man | man -l -
        ,
        .options = &.{output_option},
        .handler = manHandler,
    };
}

pub fn referenceCommand() spec.CommandSpec {
    return .{
        .name = "reference",
        .summary = "Print the Markdown command reference",
        .description =
        \\The same document committed as docs/commands.md, regenerated from the
        \\command tree.
        ,
        .options = &.{output_option},
        .handler = referenceHandler,
    };
}
