//! Apply declarative JSON patches to scene documents.

const std = @import("std");
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
    UnknownPatchOp,
    BuiltinCatalogEntry,
    CatalogEntryNotFound,
    ProjectRootRequired,
    NotAnInstance,
    MissingChildType,
} || scene_edit.Error || scene_resources.Error || scene_instance.Error || document.EditError || catalog_scan.ScanError || scene_undo.Error;

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

fn applyOneOp(
    allocator: std.mem.Allocator,
    doc: *document.Document,
    op_value: *const std.json.Value,
    options: ApplyOptions,
) Error![]const u8 {
    if (op_value.* != .object) return error.InvalidPatch;
    const op_name = try requiredString(op_value.object, "op");

    if (std.mem.eql(u8, op_name, "node_add")) {
        const parent = try requiredString(op_value.object, "parent");
        const name = try requiredString(op_value.object, "name");
        const node_type = try requiredString(op_value.object, "type");
        var added = try scene_edit.addNode(allocator, doc, parent, name, node_type);
        defer added.deinit(allocator);
        if (op_value.object.get("properties")) |props| {
            try applyNodeProperties(allocator, doc, added.path, props);
        }
        if (options.undo) |recorder| {
            try scene_undo.recordNodeAddUndo(recorder, added.path);
        }
        return std.fmt.allocPrint(allocator, "added node {s} at {s}", .{ name, added.path });
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
            try scene_undo.recordNodeReparentUndo(recorder, path, old_parent);
        }
        return std.fmt.allocPrint(allocator, "reparented {s} under {s}", .{ path, parent });
    }

    if (std.mem.eql(u8, op_name, "node_set")) {
        const path = try requiredString(op_value.object, "path");
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

        var added = try scene_resources.addExtResourceWithId(allocator, doc, res_type, path, id, scene_uid);
        defer added.deinit(allocator);
        if (options.undo) |recorder| {
            try scene_undo.recordExtRemoveUndo(recorder, added.id);
        }
        return std.fmt.allocPrint(allocator, "added ext_resource {s} ({s})", .{ added.id, path });
    }

    if (std.mem.eql(u8, op_name, "assign_ext")) {
        const node_path = try requiredString(op_value.object, "path");
        const property = try requiredString(op_value.object, "property");
        const res_type = if (op_value.object.get("type")) |type_value|
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

        var added = try scene_resources.addSubResourceWithId(allocator, doc, res_type, id, props_list.items);
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

    return error.UnknownPatchOp;
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
        const value_text = try jsonValueToPropertyText(allocator, entry.value_ptr.*);
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
        const value_text = try jsonValueToPropertyText(allocator, entry.value_ptr.*);
        errdefer allocator.free(value_text);
        const name_copy = try allocator.dupe(u8, entry.key_ptr.*);
        errdefer allocator.free(name_copy);
        try out.append(allocator, .{ .name = name_copy, .value = value_text });
    }
}

fn jsonValueToPropertyText(allocator: std.mem.Allocator, value: std.json.Value) Error![]const u8 {
    return switch (value) {
        .string => |s| try allocator.dupe(u8, s),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .integer => |i| std.fmt.allocPrint(allocator, "{d}", .{i}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        else => error.InvalidPatch,
    };
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

fn generatedSubId(allocator: std.mem.Allocator, doc: *document.Document, seed_path: []const u8, res_type: []const u8) Error![]const u8 {
    _ = doc;
    scene_resources.seedResourceIds(seed_path);
    return scene_id.formatSubResourceId(allocator, res_type);
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
    const value = map.get(key) orelse return error.MissingPatchField;
    return jsonString(value);
}

fn requiredPropertyValue(allocator: std.mem.Allocator, map: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = map.get(key) orelse return error.MissingPatchField;
    return jsonValueToPropertyText(allocator, value);
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
