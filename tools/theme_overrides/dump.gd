extends SceneTree

# Run by tools/gen_theme_overrides.sh: every theme override property each
# Control and Window class offers, as an instance lists it. That list is
# what a save writes; the class reference is close but not the same (it
# leaves out FileDialog's load, save and clear icons, for one).

func _initialize() -> void:
	var out := {}
	for cls in ClassDB.get_class_list():
		if not ClassDB.can_instantiate(cls):
			continue
		if not (ClassDB.is_parent_class(cls, "Control") or ClassDB.is_parent_class(cls, "Window")):
			continue
		var object = ClassDB.instantiate(cls)
		if object == null:
			continue
		var names := []
		for info in object.get_property_list():
			var name: String = info.name
			if name.begins_with("theme_override_") and name.contains("/"):
				names.append(name)
		out[cls] = names
		object.free()
	var file := FileAccess.open("res://theme_overrides.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": Engine.get_version_info().string, "classes": out}))
	file.close()
	quit(0)
