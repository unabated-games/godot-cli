extends Area2D

signal touched(slime: Area2D)

@export var velocity := Vector2(150, 100)

var active := false
var speed_scale := 1.0
var _time := 0.0
var _squish := 0.0


func _physics_process(delta: float) -> void:
	_time += delta
	_squish = move_toward(_squish, 0.0, 2.5 * delta)
	# A jelly wobble all the time, and a flat squish just after a bounce.
	var wobble := sin(_time * 7.0 + position.x * 0.01) * 0.07
	$Sprite.scale = Vector2(1.0 + wobble + _squish, 1.0 - wobble - _squish)
	if not active:
		return
	position += velocity * speed_scale * delta
	if position.x < 85.0 or position.x > 875.0:
		velocity.x = -velocity.x
		position.x = clampf(position.x, 85.0, 875.0)
		_squish = 0.3
	if position.y < 110.0 or position.y > 450.0:
		velocity.y = -velocity.y
		position.y = clampf(position.y, 110.0, 450.0)
		_squish = 0.3
	$Sprite.flip_h = velocity.x < 0.0
	if has_overlapping_bodies():
		touched.emit(self)


func cheer() -> void:
	var tween := create_tween()
	tween.tween_property($Sprite, "position:y", -26.0, 0.18).set_ease(Tween.EASE_OUT)
	tween.tween_property($Sprite, "position:y", 0.0, 0.22).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
