@tool
extends EditorPlugin

# Run by tools/gen_export_options.sh in a scratch project whose
# export_presets.cfg holds one bare preset per platform. The export plugin
# re-sets one option on each preset to its own value, which makes the editor
# save export_presets.cfg (and .godot/export_credentials.cfg) in full: every
# option each platform defines, in its own order, with its defaults. It also
# dumps what the editor says about each visible option (type, hint), and quits
# once the save has had time to land.

# Untyped: touched and platforms are the dump script's own members.
var dumper
var elapsed := 0.0

func _enter_tree() -> void:
	dumper = preload("dump.gd").new()
	add_export_plugin(dumper)

func _exit_tree() -> void:
	remove_export_plugin(dumper)

func _process(delta: float) -> void:
	if dumper.touched.is_empty():
		return
	elapsed += delta
	# EditorExport saves 0.8 s after the last change.
	if elapsed > 3.0:
		var file := FileAccess.open("res://export_options_dump.json", FileAccess.WRITE)
		file.store_string(JSON.stringify({"platforms": dumper.platforms, "names": dumper.names}, "\t"))
		file.close()
		get_tree().quit()
