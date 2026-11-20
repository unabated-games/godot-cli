extends Area2D

signal collected(gem: Area2D)

var _time := 0.0


func _process(delta: float) -> void:
	_time += delta
	$Sprite.position.y = sin(_time * 4.0 + position.x) * 4.0
	$Sprite.rotation = sin(_time * 2.0 + position.y) * 0.08


## Move somewhere new and pop in, after a beat so the pickup reads first.
func respawn_at(point: Vector2) -> void:
	position = point
	$Sprite.scale = Vector2.ZERO
	var tween := create_tween()
	tween.tween_interval(0.25)
	tween.tween_property($Sprite, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


# Asked every physics frame, not on body_entered: a gem can pop in underneath a
# robot that is already standing there, and nothing enters in that case.
func _physics_process(_delta: float) -> void:
	if $Sprite.scale.x > 0.5 and has_overlapping_bodies():
		collected.emit(self)
