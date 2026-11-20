extends Node2D

const START_HEARTS := 3
const SAFE_SECONDS := 1.2
const HIT_FLASH_SECONDS := 0.9
const START_SAFE_SECONDS := 2.0
const PICKUP_FX := preload("res://actors/pickup_fx.tscn")

var score := 0
var best := 0
var hearts := START_HEARTS
var playing := false
var safe_frames := 0
var rng := RandomNumberGenerator.new()

@onready var player: CharacterBody2D = $Player
@onready var hud: CanvasLayer = $HUD
@onready var gems := $Gems.get_children()
@onready var slimes := $Slimes.get_children()
@onready var gem_starts := gems.map(func(g): return g.position)
@onready var slime_starts := slimes.map(func(s): return s.position)


func _ready() -> void:
	rng.randomize()
	# `project run --user-arg --seed=7` makes a captured run repeatable.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--seed="):
			rng.seed = int(arg.trim_prefix("--seed="))
	_set_playing(false)
	hud.show_title()


func _physics_process(_delta: float) -> void:
	if safe_frames > 0:
		safe_frames -= 1


func _set_playing(on: bool) -> void:
	playing = on
	player.active = on
	for slime in slimes:
		slime.active = on


func _start() -> void:
	score = 0
	hearts = START_HEARTS
	safe_frames = int(START_SAFE_SECONDS * Engine.physics_ticks_per_second)
	player.reset(Vector2(480, 290))
	player.protect(START_SAFE_SECONDS)
	for i in slimes.size():
		slimes[i].position = slime_starts[i]
		slimes[i].speed_scale = 1.0
	for i in gems.size():
		gems[i].respawn_at(gem_starts[i])
	hud.set_score(score)
	hud.set_hearts(hearts)
	hud.show_game()
	_set_playing(true)


func _on_play_pressed() -> void:
	_start()


func _on_retry_pressed() -> void:
	_start()


func _on_gem_collected(gem: Area2D) -> void:
	if not playing:
		return
	score += 1
	hud.set_score(score)
	$Pickup.play()
	var burst := PICKUP_FX.instantiate()
	burst.position = gem.position
	add_child(burst)
	gem.respawn_at(_free_spot())
	# Every gem makes the slimes a little faster, up to twice their speed.
	for slime in slimes:
		slime.speed_scale = minf(1.0 + score * 0.04, 2.0)


## Somewhere in the clearing that is not on top of the robot or another gem.
func _free_spot() -> Vector2:
	var spot := Vector2(480, 290)
	for attempt in 20:
		spot = Vector2(rng.randf_range(100, 860), rng.randf_range(120, 440))
		var clear := spot.distance_to(player.position) > 170.0
		for gem in gems:
			clear = clear and spot.distance_to(gem.position) > 80.0
		if clear:
			break
	return spot


func _on_slime_touched(slime: Area2D) -> void:
	if not playing or safe_frames > 0:
		return
	safe_frames = int(SAFE_SECONDS * Engine.physics_ticks_per_second)
	hearts -= 1
	hud.set_hearts(hearts)
	_shake()
	if hearts > 0:
		$Hit.play()
		player.hurt(slime.position, HIT_FLASH_SECONDS)
		return
	_set_playing(false)
	best = maxi(best, score)
	$Over.play()
	player.die()
	for other in slimes:
		other.cheer()
	await get_tree().create_timer(0.9).timeout
	hud.show_game_over(score, best)


func _shake() -> void:
	var tween := create_tween()
	for i in 6:
		tween.tween_property(self, "position", Vector2(rng.randf_range(-7, 7), rng.randf_range(-7, 7)), 0.035)
	tween.tween_property(self, "position", Vector2.ZERO, 0.035)
