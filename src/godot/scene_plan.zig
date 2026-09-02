//! Expand high-level intent JSON into patch ops and preview plans (no write).

const std = @import("std");
const error_details = @import("error_details.zig");
const scene_patch = @import("scene_patch.zig");
const document = @import("text_format/document.zig");

pub const Error = error{
    OutOfMemory,
    InvalidIntent,
    MissingIntentField,
    UnknownRecipe,
    InvalidInput,
} || scene_patch.Error;

pub const PlanOptions = struct {
    project_root: ?[]const u8 = null,
    io: ?std.Io = null,
    seed_path: []const u8 = "res://scene.tscn",
};

pub const StepPlan = struct {
    index: usize,
    recipe: []const u8,
    summary: []const u8,
    op_count: usize,

    pub fn deinit(self: *const StepPlan, allocator: std.mem.Allocator) void {
        allocator.free(self.recipe);
        allocator.free(self.summary);
    }
};

pub const PlanResult = struct {
    patch_json: []const u8,
    steps: []StepPlan,
    preview: ?scene_patch.ApplyResult = null,

    pub fn deinit(self: *PlanResult, allocator: std.mem.Allocator) void {
        allocator.free(self.patch_json);
        for (self.steps) |*step| step.deinit(allocator);
        allocator.free(self.steps);
        if (self.preview) |*preview| preview.deinit(allocator);
    }
};

pub fn planFromInput(
    allocator: std.mem.Allocator,
    input_json: []const u8,
    doc: ?*document.Document,
    options: PlanOptions,
) Error!PlanResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, input_json, .{}) catch return error.InvalidIntent;
    defer parsed.deinit();

    var ops_arena = std.heap.ArenaAllocator.init(allocator);
    defer ops_arena.deinit();
    const ops_alloc = ops_arena.allocator();

    const root = parsed.value;
    if (root != .object) return error.InvalidIntent;

    var step_plans: std.ArrayList(StepPlan) = .empty;
    errdefer {
        for (step_plans.items) |*step| step.deinit(allocator);
        step_plans.deinit(allocator);
    }

    var ops = std.json.Array.init(ops_alloc);

    if (root.object.get("ops")) |existing_ops| {
        if (existing_ops != .array) return error.InvalidIntent;
        for (existing_ops.array.items) |op| try ops.append(op);
        try step_plans.append(allocator, .{
            .index = 0,
            .recipe = try allocator.dupe(u8, "patch"),
            .summary = try std.fmt.allocPrint(allocator, "passthrough patch ({d} op(s))", .{ops.items.len}),
            .op_count = ops.items.len,
        });
    } else if (root.object.get("steps")) |steps_value| {
        try expandIntentSteps(ops_alloc, steps_value, &ops, &step_plans, allocator);
    } else {
        return error.InvalidIntent;
    }

    const patch_json = try renderPatchJson(allocator, ops_alloc, ops);
    errdefer allocator.free(patch_json);

    var preview: ?scene_patch.ApplyResult = null;
    if (doc) |scene_doc| {
        preview = try scene_patch.applyPatchJson(allocator, scene_doc, patch_json, .{
            .seed_path = options.seed_path,
            .project_root = options.project_root,
            .io = options.io,
            .strict = true,
        });
    }

    return .{
        .patch_json = patch_json,
        .steps = try step_plans.toOwnedSlice(allocator),
        .preview = preview,
    };
}

fn expandIntentSteps(
    ops_alloc: std.mem.Allocator,
    steps_value: std.json.Value,
    ops: *std.json.Array,
    step_plans: *std.ArrayList(StepPlan),
    allocator: std.mem.Allocator,
) Error!void {
    if (steps_value != .array) return error.InvalidIntent;

    for (steps_value.array.items, 0..) |*step_value, index| {
        if (step_value.* != .object) return error.InvalidIntent;
        const step = step_value.object;

        if (step.get("op")) |_| {
            try ops.append(step_value.*);
            try step_plans.append(allocator, .{
                .index = index,
                .recipe = try allocator.dupe(u8, "op"),
                .summary = try std.fmt.allocPrint(allocator, "direct op {s}", .{try requiredString(step, "op")}),
                .op_count = 1,
            });
            continue;
        }

        const recipe = try requiredString(step, "recipe");
        const before = ops.items.len;
        try expandRecipe(ops_alloc, recipe, step, ops);
        const added = ops.items.len - before;

        try step_plans.append(allocator, .{
            .index = index,
            .recipe = try allocator.dupe(u8, recipe),
            .summary = try recipeSummary(allocator, recipe, step, added),
            .op_count = added,
        });
    }
}

fn expandRecipe(ops_alloc: std.mem.Allocator, recipe: []const u8, step: std.json.ObjectMap, ops: *std.json.Array) Error!void {
    if (std.mem.eql(u8, recipe, "add_node")) {
        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_add" },
            .{ "parent", try requiredString(step, "parent") },
            .{ "name", try requiredString(step, "name") },
            .{ "type", try requiredString(step, "type") },
        }));
        if (step.get("properties")) |props| {
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "properties", props);
        } else if (readBool(step.get("unique_name")) orelse false) {
            var props: std.json.ObjectMap = .{};
            try props.put(ops_alloc, "unique_name_in_owner", .{ .bool = true });
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "properties", .{ .object = props });
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "instance_catalog")) {
        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "instance_add" },
            .{ "parent", try requiredString(step, "parent") },
            .{ "name", try requiredString(step, "name") },
            .{ "catalog_id", try requiredString(step, "catalog_id") },
        }));
        if (readBool(step.get("editable")) orelse false) {
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "editable", .{ .bool = true });
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "instance_scene")) {
        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "instance_add" },
            .{ "parent", try requiredString(step, "parent") },
            .{ "name", try requiredString(step, "name") },
            .{ "scene", try requiredString(step, "scene") },
        }));
        if (readBool(step.get("editable")) orelse false) {
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "editable", .{ .bool = true });
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "node_set")) {
        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_set" },
            .{ "path", try requiredString(step, "path") },
            .{ "property", try requiredString(step, "property") },
            .{ "value", try requiredString(step, "value") },
        }));
        return;
    }

    if (std.mem.eql(u8, recipe, "assign_ext")) {
        const node_path = try requiredString(step, "path");
        const property = try requiredString(step, "property");
        const ext_type = if (step.get("ext_type") orelse step.get("type")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else if (step.get("type")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else return error.MissingIntentField;
        const res_path = if (step.get("res_path")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else if (step.get("resource_path")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else return error.MissingIntentField;
        const id_hint = if (step.get("id_hint")) |v| blk: {
            if (v != .string) return error.InvalidIntent;
            break :blk v.string;
        } else try defaultExtHint(ops_alloc, res_path, property);
        defer if (step.get("id_hint") == null) ops_alloc.free(id_hint);

        try appendAssignExt(ops_alloc, ops, node_path, property, ext_type, res_path, id_hint);
        return;
    }

    if (std.mem.eql(u8, recipe, "instance_override") or std.mem.eql(u8, recipe, "instance_set")) {
        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "instance_override" },
            .{ "path", try requiredString(step, "path") },
            .{ "property", try requiredString(step, "property") },
            .{ "value", try requiredString(step, "value") },
        }));
        const last = &ops.items[ops.items.len - 1];
        if (step.get("child")) |child_value| {
            if (child_value != .string) return error.InvalidIntent;
            try last.object.put(ops_alloc, "child", child_value);
        }
        if (step.get("type")) |type_value| {
            if (type_value != .string) return error.InvalidIntent;
            try last.object.put(ops_alloc, "type", type_value);
        }
        try last.object.put(ops_alloc, "editable", .{ .bool = readBool(step.get("editable")) orelse true });
        return;
    }

    if (std.mem.eql(u8, recipe, "catalog_button")) {
        const parent = try requiredString(step, "parent");
        const name = try requiredString(step, "name");
        const catalog_id = try requiredString(step, "catalog_id");
        const instance_path = try std.fmt.allocPrint(ops_alloc, "{s}/{s}", .{ parent, name });

        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "instance_add" },
            .{ "parent", parent },
            .{ "name", name },
            .{ "catalog_id", catalog_id },
        }));
        {
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "editable", .{ .bool = readBool(step.get("editable")) orelse true });
        }

        const label_text = blk: {
            if (step.get("label")) |label_value| {
                if (label_value != .string) return error.InvalidIntent;
                break :blk label_value.string;
            }
            if (step.get("label_text")) |label_value| {
                if (label_value != .string) return error.InvalidIntent;
                break :blk label_value.string;
            }
            break :blk null;
        };

        if (label_text) |text| {
            const child_name = if (step.get("child")) |child_value| blk: {
                if (child_value != .string) return error.InvalidIntent;
                break :blk child_value.string;
            } else "Label";
            const child_type = if (step.get("child_type")) |type_value| blk: {
                if (type_value != .string) return error.InvalidIntent;
                break :blk type_value.string;
            } else if (step.get("type")) |type_value| blk: {
                if (type_value != .string) return error.InvalidIntent;
                break :blk type_value.string;
            } else "Label";

            const quoted = try std.fmt.allocPrint(ops_alloc, "\"{s}\"", .{text});
            try ops.append(try makeOpObject(ops_alloc, &[_]Field{
                .{ "op", "instance_override" },
                .{ "path", instance_path },
                .{ "child", child_name },
                .{ "type", child_type },
                .{ "property", "text" },
                .{ "value", quoted },
            }));
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "editable", .{ .bool = readBool(step.get("editable")) orelse true });
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "player_2d")) {
        const parent = try requiredString(step, "parent");
        const name = try requiredString(step, "name");
        const player_path = try std.fmt.allocPrint(ops_alloc, "{s}/{s}", .{ parent, name });
        const shape_hint = try shapeIdHint(ops_alloc, step, name);
        defer ops_alloc.free(shape_hint);
        const shape_ref = try std.fmt.allocPrint(ops_alloc, "SubResource(\"CapsuleShape2D_{s}\")", .{shape_hint});
        defer ops_alloc.free(shape_ref);

        {
            var body_props: std.json.ObjectMap = .{};
            if (step.get("position")) |pos_value| {
                if (pos_value != .string) return error.InvalidIntent;
                try body_props.put(ops_alloc, "position", .{ .string = try ops_alloc.dupe(u8, pos_value.string) });
            }
            var body_op = try makeOpObject(ops_alloc, &[_]Field{
                .{ "op", "node_add" },
                .{ "parent", parent },
                .{ "name", name },
                .{ "type", "CharacterBody2D" },
            });
            if (body_props.count() > 0) {
                try body_op.object.put(ops_alloc, "properties", .{ .object = body_props });
            }
            try ops.append(body_op);
        }

        {
            var props: std.json.ObjectMap = .{};
            try props.put(ops_alloc, "radius", .{ .float = readFloat(step.get("radius")) orelse 8.0 });
            var sub_op = try makeOpObject(ops_alloc, &[_]Field{
                .{ "op", "sub_add" },
                .{ "type", "CapsuleShape2D" },
                .{ "id_hint", shape_hint },
            });
            try sub_op.object.put(ops_alloc, "properties", .{ .object = props });
            try ops.append(sub_op);
        }

        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_add" },
            .{ "parent", player_path },
            .{ "name", "Collision" },
            .{ "type", "CollisionShape2D" },
        }));
        {
            var props: std.json.ObjectMap = .{};
            try props.put(ops_alloc, "shape", .{ .string = try ops_alloc.dupe(u8, shape_ref) });
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "properties", .{ .object = props });
        }

        if (readBool(step.get("sprite")) orelse true) {
            const sprite_path = try std.fmt.allocPrint(ops_alloc, "{s}/Sprite", .{player_path});
            var sprite_props: std.json.ObjectMap = .{};
            if (step.get("modulate")) |mod_value| {
                if (mod_value != .string) return error.InvalidIntent;
                try sprite_props.put(ops_alloc, "modulate", .{ .string = try ops_alloc.dupe(u8, mod_value.string) });
            }
            var sprite_op = try makeOpObject(ops_alloc, &[_]Field{
                .{ "op", "node_add" },
                .{ "parent", player_path },
                .{ "name", "Sprite" },
                .{ "type", "Sprite2D" },
            });
            if (sprite_props.count() > 0) {
                try sprite_op.object.put(ops_alloc, "properties", .{ .object = sprite_props });
            }
            try ops.append(sprite_op);
            if (texturePathFromStep(step)) |texture_path| {
                const tex_hint = try defaultExtHint(ops_alloc, texture_path, "texture");
                defer ops_alloc.free(tex_hint);
                try appendAssignExt(ops_alloc, ops, sprite_path, "texture", "Texture2D", texture_path, tex_hint);
            }
        }

        if (step.get("script")) |script_value| {
            if (script_value != .string) return error.InvalidIntent;
            const script_hint = try defaultExtHint(ops_alloc, script_value.string, "script");
            defer ops_alloc.free(script_hint);
            try appendAssignExt(ops_alloc, ops, player_path, "script", "Script", script_value.string, script_hint);
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "tilemap_layer")) {
        const parent = try requiredString(step, "parent");
        const name = try requiredString(step, "name");
        var attach_parent = parent;

        if (readBool(step.get("with_tilemap")) orelse false) {
            const tilemap_name = if (step.get("tilemap_name")) |n| blk: {
                if (n != .string) return error.InvalidIntent;
                break :blk n.string;
            } else "TileMap";
            try ops.append(try makeOpObject(ops_alloc, &[_]Field{
                .{ "op", "node_add" },
                .{ "parent", parent },
                .{ "name", tilemap_name },
                .{ "type", "TileMap" },
            }));
            attach_parent = try std.fmt.allocPrint(ops_alloc, "{s}/{s}", .{ parent, tilemap_name });
        }

        if (step.get("tileset")) |tileset_val| {
            if (tileset_val == .string) {
                try ops.append(try makeOpObject(ops_alloc, &[_]Field{
                    .{ "op", "ext_add" },
                    .{ "type", "TileSet" },
                    .{ "path", tileset_val.string },
                    .{ "id_hint", "tileset" },
                }));
            }
        }

        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_add" },
            .{ "parent", attach_parent },
            .{ "name", name },
            .{ "type", "TileMapLayer" },
        }));

        if (step.get("tileset")) |tileset_val| {
            if (tileset_val == .string) {
                var props: std.json.ObjectMap = .{};
                try props.put(ops_alloc, "tile_set", .{ .string = try ops_alloc.dupe(u8, "ExtResource(\"TileSet_tileset\")") });
                const last = &ops.items[ops.items.len - 1];
                try last.object.put(ops_alloc, "properties", .{ .object = props });
            }
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "audio_player")) {
        const parent = try requiredString(step, "parent");
        const name = try requiredString(step, "name");
        const node_type = if (step.get("spatial")) |spatial| blk: {
            if (spatial != .string) return error.InvalidIntent;
            if (std.mem.eql(u8, spatial.string, "3d")) break :blk "AudioStreamPlayer3D";
            break :blk "AudioStreamPlayer2D";
        } else "AudioStreamPlayer2D";

        if (step.get("stream")) |stream_val| {
            if (stream_val == .string) {
                try ops.append(try makeOpObject(ops_alloc, &[_]Field{
                    .{ "op", "ext_add" },
                    .{ "type", "AudioStream" },
                    .{ "path", stream_val.string },
                    .{ "id_hint", "stream" },
                }));
            }
        }

        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_add" },
            .{ "parent", parent },
            .{ "name", name },
            .{ "type", node_type },
        }));

        var props: std.json.ObjectMap = .{};
        var has_props = false;

        if (step.get("stream")) |stream_val| {
            if (stream_val == .string) {
                try props.put(ops_alloc, "stream", .{ .string = try ops_alloc.dupe(u8, "ExtResource(\"AudioStream_stream\")") });
                has_props = true;
            }
        }
        if (readBool(step.get("autoplay")) orelse false) {
            try props.put(ops_alloc, "autoplay", .{ .bool = true });
            has_props = true;
        }
        if (readFloat(step.get("volume_db"))) |volume| {
            try props.put(ops_alloc, "volume_db", .{ .float = volume });
            has_props = true;
        }
        if (has_props) {
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "properties", .{ .object = props });
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "camera_2d")) {
        const parent = try requiredString(step, "parent");
        const name = try requiredString(step, "name");

        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_add" },
            .{ "parent", parent },
            .{ "name", name },
            .{ "type", "Camera2D" },
        }));

        if (readFloat(step.get("zoom")) != null or readBool(step.get("enabled")) == false) {
            var props: std.json.ObjectMap = .{};
            if (readFloat(step.get("zoom"))) |zoom| {
                const zoom_text = try std.fmt.allocPrint(ops_alloc, "Vector2({d}, {d})", .{ zoom, zoom });
                try props.put(ops_alloc, "zoom", .{ .string = zoom_text });
            }
            if (readBool(step.get("enabled")) == false) {
                try props.put(ops_alloc, "enabled", .{ .bool = false });
            }
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "properties", .{ .object = props });
        }
        return;
    }

    if (std.mem.eql(u8, recipe, "ui_panel")) {
        const parent = try requiredString(step, "parent");
        const name = try requiredString(step, "name");
        const panel_path = try std.fmt.allocPrint(ops_alloc, "{s}/{s}", .{ parent, name });

        try ops.append(try makeOpObject(ops_alloc, &[_]Field{
            .{ "op", "node_add" },
            .{ "parent", parent },
            .{ "name", name },
            .{ "type", "PanelContainer" },
        }));

        if (readBool(step.get("full_rect")) orelse false) {
            var props: std.json.ObjectMap = .{};
            try props.put(ops_alloc, "anchors_preset", .{ .integer = 15 });
            const last = &ops.items[ops.items.len - 1];
            try last.object.put(ops_alloc, "properties", .{ .object = props });
        }

        if (step.get("title")) |title_val| {
            if (title_val == .string) {
                try ops.append(try makeOpObject(ops_alloc, &[_]Field{
                    .{ "op", "node_add" },
                    .{ "parent", panel_path },
                    .{ "name", "Title" },
                    .{ "type", "Label" },
                }));
                var props: std.json.ObjectMap = .{};
                try props.put(ops_alloc, "text", .{ .string = try ops_alloc.dupe(u8, title_val.string) });
                const last = &ops.items[ops.items.len - 1];
                try last.object.put(ops_alloc, "properties", .{ .object = props });
            }
        }
        return;
    }

    return error.UnknownRecipe;
}

const Field = struct { []const u8, []const u8 };

fn makeOpObject(allocator: std.mem.Allocator, fields: []const Field) Error!std.json.Value {
    var obj: std.json.ObjectMap = .{};
    for (fields) |field| {
        try obj.put(allocator, field[0], .{ .string = try allocator.dupe(u8, field[1]) });
    }
    return .{ .object = obj };
}

fn renderPatchJson(allocator: std.mem.Allocator, ops_alloc: std.mem.Allocator, ops: std.json.Array) Error![]const u8 {
    var root: std.json.ObjectMap = .{};
    try root.put(ops_alloc, "ops", .{ .array = ops });
    const value: std.json.Value = .{ .object = root };
    return try std.json.Stringify.valueAlloc(allocator, value, .{ .whitespace = .indent_2 });
}

fn recipeSummary(allocator: std.mem.Allocator, recipe: []const u8, step: std.json.ObjectMap, op_count: usize) Error![]const u8 {
    if (std.mem.eql(u8, recipe, "player_2d")) {
        const name = step.get("name") orelse {
            error_details.record(.{ .op = recipe, .field = "name" });
            return error.MissingIntentField;
        };
        if (name != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "player_2d {s} ({d} ops)", .{ name.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "instance_catalog")) {
        const id = step.get("catalog_id") orelse {
            error_details.record(.{ .op = recipe, .field = "catalog_id" });
            return error.MissingIntentField;
        };
        if (id != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "instance catalog {s} ({d} ops)", .{ id.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "instance_override") or std.mem.eql(u8, recipe, "instance_set")) {
        const path = step.get("path") orelse {
            error_details.record(.{ .op = recipe, .field = "path" });
            return error.MissingIntentField;
        };
        if (path != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "instance_override {s} ({d} ops)", .{ path.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "catalog_button")) {
        const name = step.get("name") orelse {
            error_details.record(.{ .op = recipe, .field = "name" });
            return error.MissingIntentField;
        };
        if (name != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "catalog_button {s} ({d} ops)", .{ name.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "camera_2d")) {
        const name = step.get("name") orelse {
            error_details.record(.{ .op = recipe, .field = "name" });
            return error.MissingIntentField;
        };
        if (name != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "camera_2d {s} ({d} ops)", .{ name.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "ui_panel")) {
        const name = step.get("name") orelse {
            error_details.record(.{ .op = recipe, .field = "name" });
            return error.MissingIntentField;
        };
        if (name != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "ui_panel {s} ({d} ops)", .{ name.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "tilemap_layer")) {
        const name = step.get("name") orelse {
            error_details.record(.{ .op = recipe, .field = "name" });
            return error.MissingIntentField;
        };
        if (name != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "tilemap_layer {s} ({d} ops)", .{ name.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "audio_player")) {
        const name = step.get("name") orelse {
            error_details.record(.{ .op = recipe, .field = "name" });
            return error.MissingIntentField;
        };
        if (name != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "audio_player {s} ({d} ops)", .{ name.string, op_count });
    }
    if (std.mem.eql(u8, recipe, "assign_ext")) {
        const path = step.get("path") orelse {
            error_details.record(.{ .op = recipe, .field = "path" });
            return error.MissingIntentField;
        };
        const property = step.get("property") orelse {
            error_details.record(.{ .op = recipe, .field = "property" });
            return error.MissingIntentField;
        };
        if (path != .string or property != .string) return error.InvalidIntent;
        return std.fmt.allocPrint(allocator, "assign_ext {s}.{s} ({d} ops)", .{ path.string, property.string, op_count });
    }
    return std.fmt.allocPrint(allocator, "{s} ({d} ops)", .{ recipe, op_count });
}

fn requiredString(map: std.json.ObjectMap, key: []const u8) Error![]const u8 {
    const value = map.get(key) orelse return error.MissingIntentField;
    if (value != .string) return error.InvalidIntent;
    return value.string;
}

fn readBool(value: ?std.json.Value) ?bool {
    const v = value orelse return null;
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

fn readFloat(value: ?std.json.Value) ?f64 {
    const v = value orelse return null;
    return switch (v) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

fn texturePathFromStep(step: std.json.ObjectMap) ?[]const u8 {
    const keys = [_][]const u8{ "texture", "sprite_texture", "texture_path" };
    for (keys) |key| {
        if (step.get(key)) |v| {
            if (v == .string) return v.string;
        }
    }
    return null;
}

fn defaultExtHint(ops_alloc: std.mem.Allocator, res_path: []const u8, property: []const u8) Error![]const u8 {
    _ = property;
    const basename = if (std.mem.lastIndexOfScalar(u8, res_path, '/')) |slash|
        res_path[slash + 1 ..]
    else
        res_path;
    if (std.mem.lastIndexOfScalar(u8, basename, '.')) |dot| {
        return ops_alloc.dupe(u8, basename[0..dot]);
    }
    return ops_alloc.dupe(u8, basename);
}

fn appendAssignExt(
    ops_alloc: std.mem.Allocator,
    ops: *std.json.Array,
    node_path: []const u8,
    property: []const u8,
    ext_type: []const u8,
    res_path: []const u8,
    id_hint: []const u8,
) !void {
    var op = try makeOpObject(ops_alloc, &[_]Field{
        .{ "op", "assign_ext" },
        .{ "path", node_path },
        .{ "property", property },
        .{ "ext_type", ext_type },
        .{ "res_path", res_path },
        .{ "id_hint", id_hint },
    });
    try ops.append(op);
    _ = &op;
}

fn shapeIdHint(ops_alloc: std.mem.Allocator, step: std.json.ObjectMap, node_name: []const u8) Error![]const u8 {
    if (step.get("shape_id_hint")) |value| {
        if (value != .string) return error.InvalidIntent;
        return ops_alloc.dupe(u8, value.string);
    }
    return std.fmt.allocPrint(ops_alloc, "{s}_shape", .{node_name});
}

test "expand player_2d intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    { "recipe": "player_2d", "parent": "/root/Main", "name": "Player" }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), plan.steps.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "CharacterBody2D") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "CapsuleShape2D_Player_shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Sprite2D") != null);
}

test "expand player_2d intent with texture" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "player_2d",
        \\      "parent": "/root/Main",
        \\      "name": "Player",
        \\      "texture": "res://icon.svg"
        \\    }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "id_hint") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "icon") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "assign_ext") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "res://icon.svg") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "texture") != null);
}

test "expand assign_ext intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "assign_ext",
        \\      "path": "/root/Main/Player/Sprite",
        \\      "property": "texture",
        \\      "ext_type": "Texture2D",
        \\      "res_path": "res://icon.svg",
        \\      "id_hint": "icon"
        \\    }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "id_hint") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "icon") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "assign_ext") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "node_set") == null);
}

test "apply assign_ext texture on scene" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    { "recipe": "player_2d", "parent": "/root/Main", "name": "Player" },
        \\    {
        \\      "recipe": "assign_ext",
        \\      "path": "/root/Main/Player/Sprite",
        \\      "property": "texture",
        \\      "ext_type": "Texture2D",
        \\      "res_path": "res://icon.svg",
        \\      "id_hint": "icon"
        \\    }
        \\  ]
        \\}
    ;

    const scene_text =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
    ;
    var doc = try document.parseBytes(allocator, scene_text);
    defer doc.deinit(allocator);

    var plan = try planFromInput(allocator, intent, &doc, .{ .seed_path = "res://main.tscn" });
    defer plan.deinit(allocator);

    try std.testing.expect(plan.preview != null);
    const preview = plan.preview.?;
    try std.testing.expectEqual(@as(usize, 5), preview.applied_count);
}

test "expand two player_2d intents with shared texture" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "player_2d",
        \\      "parent": "/root/Main",
        \\      "name": "Player",
        \\      "texture": "res://icon.svg"
        \\    },
        \\    {
        \\      "recipe": "player_2d",
        \\      "parent": "/root/Main",
        \\      "name": "Ally",
        \\      "texture": "res://icon.svg",
        \\      "modulate": "Color(0.5, 1, 0.5, 1)",
        \\      "position": "Vector2(120, 0)"
        \\    }
        \\  ]
        \\}
    ;

    const scene_text =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
    ;
    var doc = try document.parseBytes(allocator, scene_text);
    defer doc.deinit(allocator);

    var plan = try planFromInput(allocator, intent, &doc, .{ .seed_path = "res://main.tscn" });
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "CapsuleShape2D_Player_shape") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "CapsuleShape2D_Ally_shape") != null);
    try std.testing.expect(plan.preview != null);
    const preview = plan.preview.?;
    try std.testing.expect(preview.applied_count > 0);
}

test "expand instance_catalog intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    { "recipe": "instance_catalog", "parent": "/root/Main", "name": "Btn", "catalog_id": "ui/button" }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "instance_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "ui/button") != null);
}

test "expand camera_2d intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    { "recipe": "camera_2d", "parent": "/root/Main", "name": "Camera", "zoom": 1.5 }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Camera2D") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Vector2(1.5, 1.5)") != null);
}

test "expand ui_panel intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    { "recipe": "ui_panel", "parent": "/root/Main", "name": "HUD", "title": "Score", "full_rect": true }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "PanelContainer") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Label") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Score") != null);
}

test "expand audio_player intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "audio_player",
        \\      "parent": "/root/Main",
        \\      "name": "Music",
        \\      "stream": "res://audio/music.ogg",
        \\      "autoplay": true,
        \\      "volume_db": -6.0
        \\    }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "AudioStreamPlayer2D") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "AudioStream_stream") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "autoplay") != null);
}

test "expand tilemap_layer intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "tilemap_layer",
        \\      "parent": "/root/Level",
        \\      "name": "Ground",
        \\      "with_tilemap": true,
        \\      "tileset": "res://tiles/grass.tres"
        \\    }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "TileMap") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "TileMapLayer") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "TileSet_tileset") != null);
}

test "expand instance_override intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "instance_override",
        \\      "path": "/root/Main/MyButton",
        \\      "child": "Label",
        \\      "type": "Label",
        \\      "property": "text",
        \\      "value": "\"Play\""
        \\    }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "instance_override") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "MyButton") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Play") != null);
}

test "expand catalog_button intent" {
    const allocator = std.testing.allocator;
    const intent =
        \\{
        \\  "steps": [
        \\    {
        \\      "recipe": "catalog_button",
        \\      "parent": "/root/Main",
        \\      "name": "StartButton",
        \\      "catalog_id": "ui/button",
        \\      "label": "Start Game"
        \\    }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, null, .{});
    defer plan.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "instance_add") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "instance_override") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "Start Game") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.patch_json, "editable") != null);
}

test "plan previews against scene" {
    const allocator = std.testing.allocator;
    const source =
        \\[gd_scene format=3]
        \\
        \\[node name="Main" type="Node2D"]
        \\
    ;
    var doc = try document.parseBytes(allocator, source);
    defer doc.deinit(allocator);

    const intent =
        \\{
        \\  "steps": [
        \\    { "recipe": "add_node", "parent": "/root/Main", "name": "HUD", "type": "CanvasLayer" }
        \\  ]
        \\}
    ;

    var plan = try planFromInput(allocator, intent, &doc, .{ .seed_path = "res://main.tscn" });
    defer plan.deinit(allocator);

    try std.testing.expect(plan.preview != null);
    try std.testing.expectEqual(@as(usize, 1), plan.preview.?.applied_count);
}
