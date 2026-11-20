extends CharacterBody2D

@export var speed := 280.0

var active := false
var _knock := Vector2.ZERO
var _time := 0.0


func _physics_process(delta: float) -> void:
	if not active:
		return
	var direction := Input.get_vector("move_left", "move_right", "move_up", "move_down")
	velocity = direction * speed + _knock
	_knock = _knock.move_toward(Vector2.ZERO, 1400.0 * delta)
	move_and_slide()
	position = position.clamp(Vector2(80, 95), Vector2(880, 455))
	# Lean into the turn and bob while moving, so the robot never slides stiffly.
	_time += delta
	if direction.x != 0.0:
		$Sprite.flip_h = direction.x < 0.0
	$Sprite.rotation = lerp_angle($Sprite.rotation, direction.x * 0.18, 12.0 * delta)
	$Sprite.position.y = sin(_time * 14.0) * 3.0 if direction != Vector2.ZERO else 0.0


func reset(point: Vector2) -> void:
	position = point
	_knock = Vector2.ZERO
	rotation = 0.0
	scale = Vector2.ONE
	modulate = Color.WHITE
	$Sprite.rotation = 0.0


## Knocked away from `from`, flashing red for `seconds`.
func hurt(from: Vector2, seconds: float) -> void:
	_knock = (position - from).normalized() * 520.0
	_blink(Color(1, 0.45, 0.45, 0.35), seconds)


## A soft shimmer while nothing can hurt the robot yet. Not red: red means a hit.
func protect(seconds: float) -> void:
	_blink(Color(1, 1, 1, 0.55), seconds)


func _blink(to: Color, seconds: float) -> void:
	var tween := create_tween().set_loops(maxi(int(seconds / 0.16), 1))
	tween.tween_property(self, "modulate", to, 0.08)
	tween.tween_property(self, "modulate", Color.WHITE, 0.08)


func die() -> void:
	active = false
	var tween := create_tween().set_parallel()
	tween.tween_property(self, "rotation", TAU * 2.0, 0.7)
	tween.tween_property(self, "scale", Vector2.ZERO, 0.7).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
