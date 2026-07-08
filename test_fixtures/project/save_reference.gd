extends SceneTree

func _init() -> void:
	var source := "res://sample.tscn"
	var dest := "res://sample_godot_saved.tscn"
	var packed: Resource = load(source)
	if packed == null:
		push_error("Failed to load %s" % source)
		quit(1)
		return
	var err: Error = ResourceSaver.save(packed, dest)
	if err != OK:
		push_error("Failed to save %s: %s" % [dest, error_string(err)])
		quit(1)
		return
	print("Saved ", dest)
	quit()
