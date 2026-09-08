extends Control

# Naming the autoload is the point: the generated run harness used to load
# this scene before Godot registered autoload names, so this line failed to
# compile and nothing ran.
func _ready() -> void:
	print("autoload fixture score=", GameState.score)
