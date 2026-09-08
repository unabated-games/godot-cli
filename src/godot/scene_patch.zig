//! Apply declarative JSON patches to scene documents.

const std = @import("std");
const error_details = @import("error_details.zig");
const scene_connections = @import("scene_connections.zig");
const variant_parse = @import("variant/parse.zig");
const document = @import("text_format/document.zig");
const scene_edit = @import("scene_edit.zig");
const scene_resources = @import("scene_resources.zig");
const scene_instance = @import("scene_instance.zig");
const resource_uid_lookup = @import("resource_uid_lookup.zig");
const catalog_scan = @import("catalog_scan.zig");
const catalog_builtins = @import("catalog_builtins.zig");
const scene_undo = @import("scene_undo.zig");

pub const Error = error{
    OutOfMemory,
    InvalidPatch,
    MissingPatchField,
    InvalidPropertyValue,
    UnknownPatchOp,
    BuiltinCatalogEntry,
    CatalogEntryNotFound,
    ProjectRootRequired,
    NotAnInstance,
    MissingChildType,
} || scene_connections.Error || scene_edit.Error || scene_resources.Error || scene_instance.Error || document.EditError || catalog_scan.ScanError || scene_undo.Error;

pub const ApplyOptions = struct {
    seed_path: []const u8,
    project_root: ?[]const u8 = null,
    io: ?std.Io = null,
    strict: bool = true,
    undo: ?*scene_undo.UndoRecorder = null,
};

pub const OpResult = struct {
    index: usize,
    op: []const u8,
    summary: []const u8,

    pub fn deinit(self: *const OpResult, allocator: std.mem.Allocator) void {
        allocator.free(self.op);
        allocator.free(self.summary);
    }
};

pub const ApplyResult = struct {
    applied_count: usize,
    results: []OpResult,

    pub fn deinit(self: *ApplyResult, allocator: std.mem.Allocator) void {
        for (self.results) |*item| item.deinit(allocator);
        allocator.free(self.results);
    }
};

pub fn applyPatchJson(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    patch_json: []const u8,
    options: ApplyOptions,
) Error!ApplyResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, patch_json, .{}) catch return error.InvalidPatch;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return error.InvalidPatch;
    const ops_value = root.object.get("ops") orelse return error.InvalidPatch;
    if (ops_value != .array) return error.InvalidPatch;

    var results: std.ArrayList(OpResult) = .empty;
    errdefer {
        for (results.items) |*item| item.deinit(allocator);
        results.deinit(allocator);
    }

    scene_resources.clearConflictDetails();

    for (ops_value.array.items, 0..) |*op_value, index| {
        const summary = applyOneOp(allocator, doc, op_value, options) catch |err| {
            error_details.noteStep(index);
            if (options.strict) return err;
            const msg = try std.fmt.allocPrint(allocator, "op {d} failed: {s}", .{ index, @errorName(err) });
            try results.append(allocator, .{
                .index = index,
                .op = try dupOpName(allocator, op_value),
                .summary = msg,
            });
            continue;
        };
        defer allocator.free(summary);
        try results.append(allocator, .{
            .index = index,
            .op = try dupOpName(allocator, op_value),
            .summary = try allocator.dupe(u8, summary),
        });
    }

    return .{
        .applied_count = results.items.len,
        .results = try results.toOwnedSlice(allocator),
    };
}

/// Every field an op accepts, so an unknown one is rejected instead of being
/// silently dropped: trial 20 wrote `"id"` where `ext_add` takes `id_hint`,
/// got a generated id, and left a later `node_set` pointing at an
/// `ExtResource("MyStyle")` that was never written.
const OpFields = struct {
    name: []const u8,
    fields: []const []const u8,
    /// `<op> takes: a, b, c`, built once at compile time for the failure hint.
    hint: []const u8,
};

fn opRow(comptime name: []const u8, comptime fields: []const []const u8) OpFields {
    comptime var hint: []const u8 = name ++ " takes: ";
    inline for (fields, 0..) |field, i| {
        hint = hint ++ (if (i == 0) "" else ", ") ++ field;
    }
    return .{ .name = name, .fields = fields, .hint = hint };
}

const op_fields = [_]OpFields{
    opRow("node_add", &.{ "parent", "name", "type", "properties", "unique_name" }),
    opRow("node_remove", &.{ "path", "recursive" }),
    opRow("node_rename", &.{ "path", "name" }),
    opRow("node_reparent", &.{ "path", "parent" }),
    opRow("node_set", &.{ "path", "property", "value", "properties" }),
    opRow("ext_add", &.{ "type", "path", "id_hint" }),
    opRow("ext_remove", &.{"id"}),
    opRow("sub_add", &.{ "type", "id_hint", "properties" }),
    opRow("sub_remove", &.{"id"}),
    opRow("assign_ext", &.{ "path", "property", "type", "ext_type", "res_path", "resource_path", "id_hint" }),
    opRow("instance_add", &.{ "parent", "name", "scene", "catalog_id", "properties", "editable", "scene_uid" }),
    opRow("instance_override", &.{ "path", "property", "value", "child", "type", "editable" }),
    opRow("connection_add", &.{ "from", "signal", "to", "method", "binds", "unbinds", "deferred", "one_shot" }),
    opRow("connection_remove", &.{ "from", "signal", "to", "method" }),
};

fn checkOpFields(op_name: []const u8, object: std.json.ObjectMap) Error!void {
    const known = for (op_fields) |row| {
        if (std.mem.eql(u8, row.name, op_name)) break row;
    } else return; // An op with no row is an unknown op, reported below.

    var it = object.iterator();
    keys: while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "op")) continue;
        for (known.fields) |field| {
            if (std.mem.eql(u8, key, field)) continue :keys;
        }
        error_details.record(.{ .field = key, .hint = known.hint });
        return error.InvalidPatch;
    }
}

/// `id_hint` is the answer to a generated id colliding, and the failure never
/// said so; trial 20 gave up on inline sub-resources and wrote four .tres
/// files instead.
fn noteIdCollision(err: anyerror, kind: enum { sub, ext }) void {
    if (err != error.DuplicateResourceId) return;
    error_details.record(.{
        .field = "id_hint",
        .hint = switch (kind) {
            .sub => "the id is generated from the resource type and the scene, so two sub_add ops of the same type collide; give each one an id_hint (\"id_hint\": \"play_normal\" writes StyleBoxFlat_play_normal)",
            .ext => "the id is generated from the scene, so two ext_add ops in one patch collide; give each one an id_hint (\"id_hint\": \"hover\" writes StyleBoxFlat_hover)",
        },
    });
}

fn applyOneOp(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    op_value: *const std.json.Value,
    options: ApplyOptions,
) Error![]const u8 {
    if (op_value.* != .object) return error.InvalidPatch;
    const op_name_given = try requiredString(op_value.object, "op");
    // Recipe names are accepted as ops too; trial 18 wrote instance_catalog
    // in a patch and got UnknownPatchOp.
    const op_name = opAlias(op_name_given);
    error_details.setCurrentOp(op_name);
    try checkOpFields(op_name, op_value.object);

    if (std.mem.eql(u8, op_name, "node_add")) {
        const parent = try requiredString(op_value.object, "parent");
        const name = try requiredString(op_value.object, "name");
        const node_type = try requiredString(op_value.object, "type");
        var added = try scene_edit.addNode(allocator, doc, parent, name, node_type);
        defer added.deinit(allocator);
        if (op_value.object.get("properties")) |props| {
            try applyNodeProperties(allocator, doc, added.path, props);
        }
        // The add_node recipe takes unique_name; the op silently dropped it.
        if (readBool(op_value.object.get("unique_name")) orelse false) {
            try scene_edit.setNodeProperty(allocator, doc, added.path, "unique_name_in_owner", "true");
        }
        if (options.undo) |recorder| {
            try scene_undo.recordNodeAddUndo(recorder, added.path);
        }
        return std.fmt.allocPrint(allocator, "added node {s} at {s}", .{ name, added.path });
    }

    if (std.mem.eql(u8, op_name, "connection_add")) {
        const from = try requiredString(op_value.object, "from");
        const signal = try requiredString(op_value.object, "signal");
        const to = try requiredString(op_value.object, "to");
        const method = try requiredString(op_value.object, "method");
        const binds = if (op_value.object.get("binds")) |b| try jsonString(b) else null;
        const unbinds: ?i64 = if (op_value.object.get("unbinds")) |u| switch (u) {
            .integer => |n| n,
            else => return error.InvalidPatch,
        } else null;
        _ = try scene_connections.add(allocator, doc, from, signal, to, method, .{
            .deferred = readBool(op_value.object.get("deferred")) orelse false,
            .one_shot = readBool(op_value.object.get("one_shot")) orelse false,
            .binds = binds,
            .unbinds = unbinds,
        });
        if (options.undo) |recorder| {
            try scene_undo.recordConnectionAddUndo(recorder, from, signal, to, method);
        }
        return std.fmt.allocPrint(allocator, "connected {s} {s} to {s} {s}", .{ from, signal, to, method });
    }

    if (std.mem.eql(u8, op_name, "connection_remove")) {
        const from = try requiredString(op_value.object, "from");
        const signal = try requiredString(op_value.object, "signal");
        const to = try requiredString(op_value.object, "to");
        const method = if (op_value.object.get("method")) |m| try jsonString(m) else null;
        if (options.undo) |recorder| {
            try scene_undo.captureConnectionRemoveUndo(recorder, allocator, doc, from, signal, to, method);
        }
        const removed = try scene_connections.remove(allocator, doc, from, signal, to, method);
        return std.fmt.allocPrint(allocator, "removed {d} connection(s) of {s} {s} to {s}", .{ removed, from, signal, to });
    }

    if (std.mem.eql(u8, op_name, "node_remove")) {
        const path = try requiredString(op_value.object, "path");
        const recursive = readBool(op_value.object.get("recursive")) orelse false;
        if (options.undo) |recorder| {
            try scene_undo.captureRemoveUndoOps(recorder, allocator, doc, path, recursive);
        }
        const removed = try scene_edit.removeNode(allocator, doc, path, recursive);
        return std.fmt.allocPrint(allocator, "removed {d} node section(s) at {s}", .{ removed, path });
    }

    if (std.mem.eql(u8, op_name, "node_rename")) {
        const path = try requiredString(op_value.object, "path");
        const name = try requiredString(op_value.object, "name");
        var list = try @import("node_tree.zig").collectNodes(allocator, doc);
        defer list.deinit(allocator);
        const target = @import("node_tree.zig").findByPath(&list, path) orelse return error.InvalidPatch;
        const old_name = try allocator.dupe(u8, target.name);
        defer allocator.free(old_name);
        const new_path = try scene_edit.renameNode(allocator, doc, path, name);
        defer allocator.free(new_path);
        if (options.undo) |recorder| {
            try scene_undo.recordNodeRenameUndo(recorder, new_path, old_name);
        }
        return std.fmt.allocPrint(allocator, "renamed {s} to {s}", .{ path, new_path });
    }

    if (std.mem.eql(u8, op_name, "node_reparent")) {
        const path = try requiredString(op_value.object, "path");
        const parent = try requiredString(op_value.object, "parent");
        var list = try @import("node_tree.zig").collectNodes(allocator, doc);
        defer list.deinit(allocator);
        const target = @import("node_tree.zig").findByPath(&list, path) orelse return error.InvalidPatch;
        const old_parent = blk: {
            const last = std.mem.lastIndexOf(u8, target.path, "/") orelse return error.InvalidPatch;
            break :blk try allocator.dupe(u8, target.path[0..last]);
        };
        defer allocator.free(old_parent);
        try scene_edit.reparentNode(allocator, doc, path, parent);
        if (options.undo) |recorder| {
            // The undo must address the node where it now lives.
            const new_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ parent, target.name });
            defer allocator.free(new_path);
            try scene_undo.recordNodeReparentUndo(recorder, new_path, old_parent);
        }
        return std.fmt.allocPrint(allocator, "reparented {s} under {s}", .{ path, parent });
    }

    if (std.mem.eql(u8, op_name, "node_set")) {
        const path = try requiredString(op_value.object, "path");
        // node_add takes a properties object, so this is what callers try
        // first; it used to be rejected as a missing `property`.
        if (op_value.object.get("properties")) |props| {
            if (op_value.object.get("property") != null) {
                error_details.record(.{ .field = "properties", .hint = "give either one property and value, or a properties object, not both" });
                return error.InvalidPatch;
            }
            if (props != .object) {
                error_details.record(.{ .field = "properties", .hint = "a JSON object of property name to value" });
                return error.InvalidPatch;
            }
            if (options.undo) |recorder| {
                var it = props.object.iterator();
                while (it.next()) |entry| {
                    if (try scene_undo.readNodePropertyRaw(allocator, doc, path, entry.key_ptr.*)) |old_value| {
                        defer allocator.free(old_value);
                        try scene_undo.recordNodeSetUndo(recorder, path, entry.key_ptr.*, old_value);
                    }
                }
            }
            try applyNodeProperties(allocator, doc, path, props);
            const count = props.object.count();
            return std.fmt.allocPrint(allocator, "set {d} {s} on {s}", .{ count, if (count == 1) "property" else "properties", path });
        }
        const property = try requiredString(op_value.object, "property");
        const value = try requiredPropertyValue(allocator, op_value.object, "value");
        defer allocator.free(value);
        if (options.undo) |recorder| {
            if (try scene_undo.readNodePropertyRaw(allocator, doc, path, property)) |old_value| {
                defer allocator.free(old_value);
                try scene_undo.recordNodeSetUndo(recorder, path, property, old_value);
            }
        }
        try scene_edit.setNodeProperty(allocator, doc, path, property, value);
        return std.fmt.allocPrint(allocator, "set {s} on {s}", .{ property, path });
    }

    if (std.mem.eql(u8, op_name, "ext_add")) {
        const res_type = try requiredString(op_value.object, "type");
        const path = try requiredString(op_value.object, "path");
        const id = if (op_value.object.get("id_hint")) |hint_value|
            try extIdFromHint(allocator, res_type, try jsonString(hint_value))
        else
            try generatedExtId(allocator, doc, options.seed_path);
        defer allocator.free(id);

        var scene_uid: ?[]const u8 = null;
        defer if (scene_uid) |uid| allocator.free(uid);
        if (options.project_root) |root| {
            if (options.io) |io| {
                scene_uid = try resource_uid_lookup.resolveExtResourceUid(allocator, io, root, path);
            }
        }

        if (scene_resources.findExtResourceByPath(doc, path)) |section_index| {
            const section = &doc.sections.items[section_index];
            const existing_id = section.header.getString("id") orelse return error.InvalidResourceKind;
            if (scene_uid) |uid| {
                try section.header.setStringField(allocator, "uid", uid);
            }
            return std.fmt.allocPrint(allocator, "reused ext_resource {s} ({s})", .{ existing_id, path });
        }

        var added = scene_resources.addExtResourceWithId(allocator, doc, res_type, path, id, scene_uid) catch |err| {
            noteIdCollision(err, .ext);
            return err;
        };
        defer added.deinit(allocator);
        if (options.undo) |recorder| {
            try scene_undo.recordExtRemoveUndo(recorder, added.id);
        }
        return std.fmt.allocPrint(allocator, "added ext_resource {s} ({s})", .{ added.id, path });
    }

    if (std.mem.eql(u8, op_name, "assign_ext")) {
        const node_path = try requiredString(op_value.object, "path");
        const property = try requiredString(op_value.object, "property");
        const res_type = if (op_value.object.get("type") orelse op_value.object.get("ext_type")) |type_value|
            try jsonString(type_value)
        else if (op_value.object.get("ext_type")) |type_value|
            try jsonString(type_value)
        else
            return error.MissingPatchField;
        const res_path = if (op_value.object.get("res_path")) |res_path_value|
            try jsonString(res_path_value)
        else if (op_value.object.get("resource_path")) |res_path_value|
            try jsonString(res_path_value)
        else
            return error.MissingPatchField;

        const id = if (op_value.object.get("id_hint")) |hint_value|
            try extIdFromHint(allocator, res_type, try jsonString(hint_value))
        else
            try generatedExtId(allocator, doc, options.seed_path);
        defer allocator.free(id);

        var scene_uid: ?[]const u8 = null;
        defer if (scene_uid) |uid| allocator.free(uid);
        if (options.project_root) |root| {
            if (options.io) |io| {
                scene_uid = try resource_uid_lookup.resolveExtResourceUid(allocator, io, root, res_path);
            }
        }

        const reused = scene_resources.findExtResourceByPath(doc, res_path) != null;
        var added = try scene_resources.getOrAddExtResourceWithId(
            allocator,
            doc,
            options.seed_path,
            res_type,
            res_path,
            id,
            scene_uid,
        );
        defer added.deinit(allocator);

        if (!reused) {
            if (options.undo) |recorder| {
                try scene_undo.recordExtRemoveUndo(recorder, added.id);
            }
        }

        const ext_ref = try std.fmt.allocPrint(allocator, "ExtResource(\"{s}\")", .{added.id});
        defer allocator.free(ext_ref);
        if (options.undo) |recorder| {
            if (try scene_undo.readNodePropertyRaw(allocator, doc, node_path, property)) |old_value| {
                defer allocator.free(old_value);
                try scene_undo.recordNodeSetUndo(recorder, node_path, property, old_value);
            }
        }
        try scene_edit.setNodeProperty(allocator, doc, node_path, property, ext_ref);

        const verb = if (reused) "reused" else "added";
        return std.fmt.allocPrint(allocator, "{s} ext_resource {s} and set {s} on {s}", .{ verb, added.id, property, node_path });
    }

    if (std.mem.eql(u8, op_name, "ext_remove")) {
        const id = try requiredString(op_value.object, "id");
        if (options.undo) |recorder| {
            try scene_undo.captureExtAddUndo(recorder, allocator, doc, id);
        }
        _ = try scene_resources.removeExtResource(allocator, doc, id);
        return std.fmt.allocPrint(allocator, "removed ext_resource {s}", .{id});
    }

    if (std.mem.eql(u8, op_name, "sub_add")) {
        const res_type = try requiredString(op_value.object, "type");
        const id = if (op_value.object.get("id_hint")) |hint_value|
            try subIdFromHint(allocator, res_type, try jsonString(hint_value))
        else
            try generatedSubId(allocator, doc, options.seed_path, res_type);
        defer allocator.free(id);

        var props_list: std.ArrayList(scene_resources.PropertyInput) = .empty;
        defer {
            for (props_list.items) |item| {
                allocator.free(item.name);
                allocator.free(item.value);
            }
            props_list.deinit(allocator);
        }
        if (op_value.object.get("properties")) |props| {
            try collectPropertyInputs(allocator, props, &props_list);
        }

        var added = scene_resources.addSubResourceWithId(allocator, doc, res_type, id, props_list.items) catch |err| {
            noteIdCollision(err, .sub);
            return err;
        };
        defer added.deinit(allocator);
        if (options.undo) |recorder| {
            try scene_undo.recordSubRemoveUndo(recorder, added.id);
        }
        return std.fmt.allocPrint(allocator, "added sub_resource {s}", .{added.id});
    }

    if (std.mem.eql(u8, op_name, "sub_remove")) {
        const id = try requiredString(op_value.object, "id");
        if (options.undo) |recorder| {
            try scene_undo.captureSubAddUndo(recorder, allocator, doc, id);
        }
        _ = try scene_resources.removeSubResource(allocator, doc, id);
        return std.fmt.allocPrint(allocator, "removed sub_resource {s}", .{id});
    }

    if (std.mem.eql(u8, op_name, "instance_add")) {
        const parent = try requiredString(op_value.object, "parent");
        const name = try requiredString(op_value.object, "name");
        const editable = readBool(op_value.object.get("editable")) orelse false;

        const scene_res_path = try resolveScenePath(allocator, op_value.object, options);
        defer allocator.free(scene_res_path);

        var scene_uid: ?[]const u8 = null;
        defer if (scene_uid) |uid| allocator.free(uid);
        if (op_value.object.get("scene_uid")) |uid_value| {
            scene_uid = try allocator.dupe(u8, try jsonString(uid_value));
        } else if (options.project_root) |root| {
            if (options.io) |io| {
                scene_uid = try scene_instance.readSceneUidFromResPath(allocator, io, root, scene_res_path);
            }
        }

        var added = try scene_instance.addPackedSceneInstance(
            allocator,
            doc,
            options.seed_path,
            parent,
            name,
            scene_res_path,
            scene_uid,
            editable,
        );
        defer added.deinit(allocator);
        if (op_value.object.get("properties")) |props| {
            try applyNodeProperties(allocator, doc, added.path, props);
        }
        if (options.undo) |recorder| {
            try scene_undo.recordNodeAddUndo(recorder, added.path);
        }
        return std.fmt.allocPrint(allocator, "instanced {s} at {s} from {s}", .{ name, added.path, scene_res_path });
    }

    if (std.mem.eql(u8, op_name, "instance_override")) {
        const path = try requiredString(op_value.object, "path");
        const property = try requiredString(op_value.object, "property");
        const value = try requiredPropertyValue(allocator, op_value.object, "value");
        defer allocator.free(value);
        const ensure_editable = readBool(op_value.object.get("editable")) orelse true;

        const child_name = if (op_value.object.get("child")) |child_value|
            try jsonString(child_value)
        else
            null;

        if (child_name) |name| {
            const child_type = if (op_value.object.get("type")) |type_value|
                try jsonString(type_value)
            else
                null;

            const child_path_guess = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, name });
            defer allocator.free(child_path_guess);
            if (options.undo) |recorder| {
                if (try scene_undo.readNodePropertyRaw(allocator, doc, child_path_guess, property)) |old_value| {
                    defer allocator.free(old_value);
                    try scene_undo.recordNodeSetUndo(recorder, child_path_guess, property, old_value);
                }
            }

            const child_path = try scene_instance.setInstanceChildOverride(
                allocator,
                doc,
                path,
                name,
                child_type,
                property,
                value,
                ensure_editable,
            );
            defer allocator.free(child_path);
            return std.fmt.allocPrint(allocator, "overrode {s}.{s} on instance child {s}", .{ name, property, path });
        }

        if (options.undo) |recorder| {
            if (try scene_undo.readNodePropertyRaw(allocator, doc, path, property)) |old_value| {
                defer allocator.free(old_value);
                try scene_undo.recordNodeSetUndo(recorder, path, property, old_value);
            }
        }
        try scene_instance.setInstanceProperty(allocator, doc, path, property, value);
        return std.fmt.allocPrint(allocator, "overrode {s} on instance {s}", .{ property, path });
    }

    error_details.record(.{ .field = "op", .value = op_name_given, .hint = "ops: node_add, node_remove, node_rename, node_reparent, node_set, instance_add, instance_override, ext_add, ext_remove, sub_add, sub_remove, assign_ext, connection_add, connection_remove; recipe names add_node, connect, instance_catalog, instance_scene, instance_set are accepted as aliases" });
    return error.UnknownPatchOp;
}

fn opAlias(name: []const u8) []const u8 {
    const aliases = [_][2][]const u8{
        .{ "add_node", "node_add" },
        .{ "connect", "connection_add" },
        .{ "instance_catalog", "instance_add" },
        .{ "instance_scene", "instance_add" },
        .{ "instance_set", "instance_override" },
        .{ "set", "node_set" },
    };
    for (aliases) |pair| if (std.mem.eql(u8, pair[0], name)) return pair[1];
    return name;
}

fn resolveScenePath(allocator: std.mem.Allocator, op_object: std.json.ObjectMap, options: ApplyOptions) Error![]const u8 {
    const scene_opt = op_object.get("scene");
    const catalog_opt = op_object.get("catalog_id");
    if ((scene_opt == null and catalog_opt == null) or (scene_opt != null and catalog_opt != null)) {
        return error.MissingPatchField;
    }

    if (scene_opt) |scene_value| {
        return try allocator.dupe(u8, try jsonString(scene_value));
    }

    const catalog_id = try jsonString(catalog_opt.?);
    if (catalog_builtins.isBuiltinId(catalog_id)) return error.BuiltinCatalogEntry;

    const project_root = options.project_root orelse return error.ProjectRootRequired;
    const io = options.io orelse return error.ProjectRootRequired;

    var scan = try catalog_scan.scanProject(allocator, io, project_root);
    defer scan.deinit(allocator);
    const entry = catalog_scan.findValidEntryById(scan.entries, catalog_id) orelse return error.CatalogEntryNotFound;
    return try allocator.dupe(u8, entry.scene);
}

fn applyNodeProperties(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    node_path: []const u8,
    props_value: std.json.Value,
) Error!void {
    if (props_value != .object) return error.InvalidPatch;
    var it = props_value.object.iterator();
    while (it.next()) |entry| {
        const value_text = try jsonValueToPropertyText(allocator, entry.key_ptr.*, entry.value_ptr.*);
        defer allocator.free(value_text);
        try scene_edit.setNodeProperty(allocator, doc, node_path, entry.key_ptr.*, value_text);
    }
}

fn collectPropertyInputs(
    allocator: std.mem.Allocator,
    props_value: std.json.Value,
    out: *std.ArrayList(scene_resources.PropertyInput),
) Error!void {
    if (props_value != .object) return error.InvalidPatch;
    var it = props_value.object.iterator();
    while (it.next()) |entry| {
        const value_text = try jsonValueToPropertyText(allocator, entry.key_ptr.*, entry.value_ptr.*);
        errdefer allocator.free(value_text);
        const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name_copy);
        try out.append(allocator, .{ .name = name_copy, .value = value_text });
    }
}

/// A JSON string is Variant text, not a Godot string: `"Vector2(1, 2)"` is a
/// vector and `"\"Paused\""` is a string. A bare `"Paused"` is neither, and
/// writing it produces `text = Paused`, which Godot cannot load. Rejecting it
/// with the quoted form in `details.hint` lets an agent fix its own patch.
/// Properties the editor always writes as floats. A JSON `8` for one of these
/// would otherwise land as `offset_left = 8`, which Godot loads but the editor
/// rewrites as `8.0` on the next save. Names are matched by prefix or exactly.
pub fn isFloatProperty(property: []const u8) bool {
    const name = if (std.mem.lastIndexOfScalar(u8, property, '/')) |slash| property[slash + 1 ..] else property;
    const prefixes = [_][]const u8{ "offset_", "anchor_", "rotation", "skew", "radius", "height", "volume_db", "pitch_scale", "gravity_scale", "mass", "friction", "bounce", "speed_scale", "wait_time", "energy", "range", "attenuation", "max_distance", "unit_size", "step", "min_value", "max_value", "value", "ratio", "stretch_ratio", "fov", "near", "far", "size_flags_stretch_ratio", "line_spacing", "outline_size" };
    for (prefixes) |prefix| if (std.mem.startsWith(u8, name, prefix)) return true;
    return false;
}

fn jsonValueToPropertyText(allocator: std.mem.Allocator, property: []const u8, value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |s| {
            try rejectRawVariantText(allocator, property, s);
            return try allocator.dupe(u8, s);
        },
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .integer => |i| if (isFloatProperty(property)) std.fmt.allocPrint(allocator, "{d}.0", .{i}) else std.fmt.allocPrint(allocator, "{d}", .{i}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        else => error.InvalidPatch,
    };
}

pub fn rejectRawVariantText(allocator: std.mem.Allocator, property: []const u8, text: []const u8) Error!void {
    var parsed = variant_parse.parsePropertyValue(allocator, text) catch return;
    defer parsed.deinit(allocator);
    if (parsed.kind != .raw) return;

    const hint = try std.fmt.allocPrint(allocator, "not valid Variant text; for a string write \"\\\"{s}\\\"\"", .{text});
    error_details.record(.{ .field = property, .value = text, .hint = hint });
    return error.InvalidPropertyValue;
}

fn extIdFromHint(allocator: std.mem.Allocator, res_type: []const u8, hint: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ res_type, hint });
}

fn subIdFromHint(allocator: std.mem.Allocator, res_type: []const u8, hint: []const u8) Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}", .{ res_type, hint });
}

fn generatedExtId(allocator: std.mem.Allocator, doc: *const document.Document, seed_path: []const u8) Error![]const u8 {
    scene_resources.seedResourceIds(seed_path);
    const index = countExtResources(doc) + 1;
    return scene_id.formatExtResourceId(allocator, @intCast(index));
}

/// The id is seeded from the scene path and the type, so two `sub_add` ops of
/// one type in a scene generate the same id. Three trials hit that collision;
/// one of them hand-edited the scene to get past it. A generated id steps
/// aside instead — `id_hint` is still the way to choose a stable name, and an
/// explicit hint that collides still fails, because that one is the caller's.
fn generatedSubId(allocator: std.mem.Allocator, doc: *document.Document, seed_path: []const u8, res_type: []const u8) Error![]const u8 {
    return scene_resources.generateFreeSubId(allocator, doc, seed_path, res_type);
}

const scene_id = @import("scene_id.zig");

fn countExtResources(doc: *const document.Document) usize {
    var total: usize = 0;
    for (doc.sections.items) |section| {
        if (std.mem.eql(u8, section.header.name, "ext_resource")) total += 1;
    }
    return total;
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = map.get(key) orelse {
        error_details.record(.{ .field = key });
        return error.MissingPatchField;
    };
    return jsonString(value);
}

fn requiredPropertyValue(allocator: std.mem.Allocator, map: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = map.get(key) orelse {
        error_details.record(.{ .field = key });
        return error.MissingPatchField;
    };
    const property = if (map.get("property")) |name| (jsonString(name) catch key) else key;
    return jsonValueToPropertyText(allocator, property, value);
}

fn jsonString(value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidPatch,
    };
}

fn readBool(value: ?std.json.Value) ?bool {
    const v = value orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn dupOpName(allocator: std.mem.Allocator, op_value: *const std.json.Value) Error![]const u8 {
    if (op_value.* != .object) return try allocator.dupe(u8, "invalid");
    if (op_value.object.get("op")) |name_value| {
        if (name_value == .string) return try allocator.dupe(u8, name_value.string);
    }
    return try allocator.dupe(u8, "unknown");
}

test "apply patch builds player collision" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    { "op": "node_add", "parent": "/root/Main", "name": "Player", "type": "CharacterBody2D" },
        \\    { "op": "sub_add", "type": "CapsuleShape2D", "id_hint": "shape", "properties": { "radius": 8.0 } },
        \\    {
        \\      "op": "node_add",
        \\      "parent": "/root/Main/Player",
        \\      "name": "Collision",
        \\      "type": "CollisionShape2D",
        \\      "properties": { "shape": "SubResource(\"CapsuleShape2D_shape\")" }
        \\    }
        \\  ]
        \\}
    ;

    var result = try applyPatchJson(allocator, &doc, patch, .{
        .seed_path = "res://main.tscn",
    });
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), result.applied_count);
    try std.testing.expectEqual(@as(usize, 5), doc.sections.items.len);

    var list = try @import("node_tree.zig").collectNodes(allocator, &doc);
    defer list.deinit(allocator);
    try std.testing.expect(@import("node_tree.zig").findByPath(&list, "/root/Main/Player/Collision") != null);
}

test "assign_ext reuses existing texture ext_resource" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[ext_resource type="Texture2D" path="res://icon.svg" id="Texture2D_icon"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="Sprite" type="Sprite2D" parent="."]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    {
        \\      "op": "assign_ext",
        \\      "path": "/root/Main/Sprite",
        \\      "property": "texture",
        \\      "ext_type": "Texture2D",
        \\      "res_path": "res://icon.svg",
        \\      "id_hint": "tex"
        \\    }
        \\  ]
        \\}
    ;

    var result = try applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.applied_count);
    try std.testing.expectEqualStrings("texture = ExtResource(\"Texture2D_icon\")", doc.sections.items[3].properties.items[0].raw);
}

test "duplicate sub resource id records conflict details" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[sub_resource type="CapsuleShape2D" id="CapsuleShape2D_shape"]
        \\radius = 8
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    { "op": "sub_add", "type": "CapsuleShape2D", "id_hint": "shape" }
        \\  ]
        \\}
    ;

    const result = applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" });
    try std.testing.expectError(error.DuplicateResourceId, result);
    var details = (scene_resources.conflictDetailsJson(allocator) catch null) orelse return error.TestExpectedEqual;
    defer details.deinit(allocator);
    try std.testing.expectEqualStrings("duplicate_resource_id", details.get("conflict_kind").?.string);
    try std.testing.expectEqualStrings("sub_resource", details.get("section_name").?.string);
    try std.testing.expectEqualStrings("CapsuleShape2D_shape", details.get("id").?.string);
    scene_resources.releaseConflictDetails(allocator);
}

test "apply patch removes ext resource" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[ext_resource type="Script" path="res://unused.gd" id="1_unused"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    { "op": "ext_remove", "id": "1_unused" }
        \\  ]
        \\}
    ;

    var result = try applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), doc.sections.items.len);
}

test "apply patch instance override on child" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[ext_resource type="PackedScene" path="res://ui/button/button.tscn" id="1_btn"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
        \\[node name="MyButton" parent="." instance=ExtResource("1_btn")]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    {
        \\      "op": "instance_override",
        \\      "path": "/root/Main/MyButton",
        \\      "child": "Label",
        \\      "type": "Label",
        \\      "property": "text",
        \\      "value": "\"Play\""
        \\    }
        \\  ]
        \\}
    ;

    var result = try applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" });
    defer result.deinit(allocator);
    var list = try @import("node_tree.zig").collectNodes(allocator, &doc);
    defer list.deinit(allocator);
    const label = @import("node_tree.zig").findByPath(&list, "/root/Main/MyButton/Label") orelse return error.TestExpectedEqual;
    _ = label;
}

test "an unknown field on an op is rejected and names the fields the op takes" {
    // Recorded details point into the patch JSON and the handler's allocator,
    // which the CLI keeps alive in its arena; the test matches that contract.
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    // "id" instead of "id_hint": accepted and dropped before, so a later
    // node_set referencing that id wrote a dangling ExtResource.
    const patch =
        \\{
        \\  "ops": [
        \\    { "op": "ext_add", "type": "Texture2D", "path": "res://icon.svg", "id": "MyIcon" }
        \\  ]
        \\}
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" }));

    var details = (error_details.takeJson(allocator) catch null) orelse return error.TestExpectedEqual;
    defer details.deinit(allocator);
    try std.testing.expectEqualStrings("id", details.get("field").?.string);
    try std.testing.expectEqualStrings("ext_add takes: type, path, id_hint", details.get("hint").?.string);
    try std.testing.expectEqual(@as(i64, 0), details.get("step").?.integer);
    // Nothing was written: the op is rejected before it runs.
    try std.testing.expectEqual(@as(usize, 2), doc.sections.items.len);
}

test "two sub_add ops of one type get different ids instead of colliding" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    { "op": "sub_add", "type": "StyleBoxFlat" },
        \\    { "op": "sub_add", "type": "StyleBoxFlat" },
        \\    { "op": "sub_add", "type": "StyleBoxFlat" }
        \\  ]
        \\}
    ;
    var result = try applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), result.applied_count);

    var ids: std.ArrayList([]const u8) = .empty;
    for (doc.sections.items) |section| {
        if (!std.mem.eql(u8, section.header.name, "sub_resource")) continue;
        try ids.append(allocator, section.header.getString("id").?);
    }
    try std.testing.expectEqual(@as(usize, 3), ids.items.len);
    for (ids.items, 0..) |id, i| {
        for (ids.items[i + 1 ..]) |other| try std.testing.expect(!std.mem.eql(u8, id, other));
    }
    try std.testing.expect(std.mem.endsWith(u8, ids.items[1], "_2"));
    try std.testing.expect(std.mem.endsWith(u8, ids.items[2], "_3"));
}

test "an id_hint the caller chose still fails when it collides, naming id_hint" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[sub_resource type="StyleBoxFlat" id="StyleBoxFlat_hover"]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{ "ops": [ { "op": "sub_add", "type": "StyleBoxFlat", "id_hint": "hover" } ] }
    ;
    try std.testing.expectError(error.DuplicateResourceId, applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" }));
    var details = (error_details.takeJson(allocator) catch null) orelse return error.TestExpectedEqual;
    defer details.deinit(allocator);
    try std.testing.expectEqualStrings("id_hint", details.get("field").?.string);
    try std.testing.expectEqual(@as(i64, 0), details.get("step").?.integer);
    scene_resources.releaseConflictDetails(allocator);
}

test "node_set takes a properties object, and node_add takes unique_name" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const allocator = arena_state.allocator();
    const source =
        \\[gd_scene load_steps=2 format=3]
        \\
        \\[node name="Main" type="Control"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const patch =
        \\{
        \\  "ops": [
        \\    { "op": "node_set", "path": "/root/Main", "properties": { "anchor_right": 1.0, "anchor_bottom": 1.0 } },
        \\    { "op": "node_add", "parent": "/root/Main", "name": "Score", "type": "Label", "unique_name": true }
        \\  ]
        \\}
    ;
    var result = try applyPatchJson(allocator, &doc, patch, .{ .seed_path = "res://main.tscn" });
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), result.applied_count);

    const text = try @import("text_format/roundtrip.zig").writeDocumentPreserving(allocator, &doc);
    try std.testing.expect(std.mem.indexOf(u8, text, "anchor_right = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "anchor_bottom = 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "unique_name_in_owner = true") != null);

    // One property and a properties object in the same op is a mistake, not a merge.
    const both =
        \\{ "ops": [ { "op": "node_set", "path": "/root/Main", "property": "visible", "value": "false", "properties": { "visible": "true" } } ] }
    ;
    try std.testing.expectError(error.InvalidPatch, applyPatchJson(allocator, &doc, both, .{ .seed_path = "res://main.tscn" }));
}

test "every op the dispatcher knows has a field row" {
    // A new op without a row would silently accept anything.
    const names = [_][]const u8{
        "node_add",       "node_remove",       "node_rename",  "node_reparent",
        "node_set",       "ext_add",           "ext_remove",   "sub_add",
        "sub_remove",     "assign_ext",        "instance_add", "instance_override",
        "connection_add", "connection_remove",
    };
    for (names) |name| {
        const found = for (op_fields) |row| {
            if (std.mem.eql(u8, row.name, name)) break true;
        } else false;
        try std.testing.expect(found);
    }
    try std.testing.expectEqual(names.len, op_fields.len);
}
