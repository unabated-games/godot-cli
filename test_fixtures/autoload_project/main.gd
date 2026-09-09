extends Control

# Naming the autoload is the point: the generated run harness used to load
# this scene before Godot registered autoload names, so this line failed to
# compile and nothing ran.
func _ready() -> void:
	print("autoload fixture score=", GameState.score)


# Counted so a run can assert that --frames N is N frames. Godot paces physics
# off the wall clock unless told otherwise, while --quit-after counts main-loop
# iterations; when those drift apart, input scheduled late in a run is never
# delivered and the run still exits 0.
var _physics_frames := 0


func _physics_process(_delta: float) -> void:
	_physics_frames += 1


func _exit_tree() -> void:
	print("autoload fixture physics_frames=", _physics_frames)


# The button is centred in the 320x180 viewport, so its centre is far outside
# the 64x64 a headless display server leaves behind. This line printing is the
# proof that a headless click reached a real layout.
func _on_play_pressed() -> void:
	print("autoload fixture play pressed")
