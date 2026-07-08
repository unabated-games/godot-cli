extends SceneTree

func _initialize() -> void:
	var path := "res://test.tscn"
	var project_name: String = ProjectSettings.get_setting("application/config/name")
	print("project_name: ", project_name)

	var uid := ResourceUID.create_id_for_path(path)
	print("create_id_for_path uid int: ", uid)
	print("create_id_for_path uid text: ", ResourceUID.id_to_text(uid))
	print("file md5: ", FileAccess.get_md5(path))

	for sample in [0, 1, 34, 123456789, 9223372036854775807]:
		var text := ResourceUID.id_to_text(sample)
		print("id_to_text(", sample, "): ", text)
		print("text_to_id(", text, "): ", ResourceUID.text_to_id(text))

	for i in 5:
		print("scene_unique_id[", i, "]: ", Resource.generate_scene_unique_id())

	print("path.hash(): ", path.hash())

	quit()
