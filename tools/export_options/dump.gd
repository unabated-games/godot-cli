@tool
extends EditorExportPlugin

var touched := {}
var platforms := {}
# os_name -> the platform name a preset's `platform` key holds.
var names := {}

func _get_name() -> String:
	return "godot_cli_export_options"

func _should_update_export_options(platform: EditorExportPlatform) -> bool:
	var os_name := platform.get_os_name()
	if not platforms.has(os_name):
		platforms[os_name] = {}
		var fresh := platform.create_preset()
		for info in fresh.get_property_list():
			if info.usage & PROPERTY_USAGE_STORAGE == 0:
				continue
			platforms[os_name][info.name] = {
				"type": type_string(info.type),
				"hint": info.hint,
				"hint_string": info.hint_string,
				"enum": info.hint == PROPERTY_HINT_ENUM,
				"secret": info.usage & PROPERTY_USAGE_SECRET != 0,
			}
	for preset in platform.get_current_presets():
		var key: String = preset.get_preset_name()
		if touched.has(key):
			continue
		touched[key] = true
		names[os_name] = key
		# Any real option, set to the value it already has. An unknown key
		# would do in 4.8, but 4.7 saves unknown keys into the file.
		preset.set("custom_template/debug", preset.get("custom_template/debug"))
	return false
