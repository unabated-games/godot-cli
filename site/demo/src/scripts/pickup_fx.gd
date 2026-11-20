extends Node2D

## The burst left behind where a gem was picked up. The game spawns one at run
## time, it plays once, and then it frees itself.


func _ready() -> void:
	$Sparkle.emitting = true
	var tween := create_tween().set_parallel()
	tween.tween_property($Plus, "position:y", $Plus.position.y - 46.0, 0.6).set_ease(Tween.EASE_OUT)
	tween.tween_property($Plus, "modulate:a", 0.0, 0.6).set_ease(Tween.EASE_IN)
	tween.chain().tween_callback(queue_free)
