extends SceneTree

## Headless script: save Godot-authored variant fixtures for CLI tests.
##
## DEV / TEST INFRASTRUCTURE ONLY — not the scene authoring pattern this project promotes.
## Agents and game code should persist structure in .tscn (scene node add, scene instance add),
## not build scenes at runtime with PackedScene.pack() / instantiate().
##
## Run: godot --headless --path test_fixtures/project --script save_rich_fixtures.gd

const SCENE_PATH := "res://rich_variants.tscn"
const SCENE_SAVED_PATH := "res://rich_variants_godot_saved.tscn"
const MATERIAL_PATH := "res://sample_material.tres"
const MATERIAL_SAVED_PATH := "res://sample_material_godot_saved.tres"


func _init() -> void:
	if not _build_and_save_scene():
		quit(1)
		return
	if not _save_material_reference():
		quit(1)
		return
	print("Saved rich variant fixtures")
	quit()


func _build_and_save_scene() -> bool:
	var root := Node3D.new()
	root.name = "Root"

	var holder_script: Script = load("res://variant_fixture_holder.gd")
	if holder_script == null:
		push_error("Failed to load variant_fixture_holder.gd")
		return false

	var holder := Node.new()
	holder.name = "VariantHolder"
	holder.set_script(holder_script)

	var gradient := Gradient.new()
	gradient.set_color(0, Color.WHITE)
	gradient.set_color(1, Color.BLACK)

	holder.set("meta_gradient", gradient)
	var typed_array: Array[int] = [1, 2, 3]
	holder.set("meta_array", typed_array)
	var typed_dict: Dictionary[String, int] = { "a": 1, "count": 3 }
	holder.set("meta_dictionary", typed_dict)
	holder.set("meta_plain_array", [1, 2, Vector3(1, 2, 3)])
	holder.set("meta_plain_dictionary", { "enabled": true, "count": 3 })
	holder.set("meta_packed_bytes", PackedByteArray([1, 2, 3]))
	holder.set("meta_color", Color(1.0, 0.25, 0.5, 1.0))

	root.add_child(holder)
	holder.owner = root

	var packed := PackedScene.new()
	var err := packed.pack(root)
	if err != OK:
		push_error("Failed to pack scene: %s" % error_string(err))
		return false

	err = ResourceSaver.save(packed, SCENE_PATH)
	if err != OK:
		push_error("Failed to save %s: %s" % [SCENE_PATH, error_string(err)])
		return false
	print("Saved ", SCENE_PATH)

	var err2: Error = ResourceSaver.save(packed, SCENE_SAVED_PATH)
	if err2 != OK:
		push_error("Failed to save %s: %s" % [SCENE_SAVED_PATH, error_string(err2)])
		return false
	print("Saved ", SCENE_SAVED_PATH)
	return true


func _save_material_reference() -> bool:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.25, 0.5, 1.0)
	mat.metallic = 0.35
	mat.roughness = 0.65
	mat.emission = Color(0.1, 0.2, 0.3, 1.0)

	var err: Error = ResourceSaver.save(mat, MATERIAL_PATH)
	if err != OK:
		push_error("Failed to save %s: %s" % [MATERIAL_PATH, error_string(err)])
		return false
	print("Saved ", MATERIAL_PATH)

	var err2: Error = ResourceSaver.save(mat, MATERIAL_SAVED_PATH)
	if err2 != OK:
		push_error("Failed to save %s: %s" % [MATERIAL_SAVED_PATH, error_string(err2)])
		return false
	print("Saved ", MATERIAL_SAVED_PATH)
	return true
