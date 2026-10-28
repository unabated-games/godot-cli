extends SceneTree

# Run by tools/gen_property_order.sh: each class's own stored properties, in
# the order the class registers them, which is the order a save writes them.

func _initialize() -> void:
	var out := {}
	for cls in ClassDB.get_class_list():
		var names := []
		for info in ClassDB.class_get_property_list(cls, true):
			if info.usage & PROPERTY_USAGE_STORAGE == 0:
				continue
			if info.usage & (PROPERTY_USAGE_CATEGORY | PROPERTY_USAGE_GROUP | PROPERTY_USAGE_SUBGROUP):
				continue
			names.append(info.name)
		out[cls] = names
	var file := FileAccess.open("res://property_order.json", FileAccess.WRITE)
	file.store_string(JSON.stringify({"version": Engine.get_version_info().string, "classes": out}))
	file.close()
	quit(0)
