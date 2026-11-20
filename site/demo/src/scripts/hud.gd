extends CanvasLayer

signal play_pressed
signal retry_pressed

const LOST := Color(0.16, 0.13, 0.25, 0.85)


func set_score(value: int) -> void:
	%Score.text = str(value)
	if value > 0:
		_pop(%ScorePill, 1.25)


func set_hearts(count: int) -> void:
	var hearts := %Hearts.get_children()
	for i in hearts.size():
		var full := i < count
		if not full and hearts[i].modulate == Color.WHITE:
			_pop(hearts[i], 1.6)
		hearts[i].modulate = Color.WHITE if full else LOST


func show_title() -> void:
	%GameOverCard.visible = false
	_show_card(%TitleCard)


func show_game() -> void:
	%TitleCard.visible = false
	%GameOverCard.visible = false


func show_game_over(score: int, best: int) -> void:
	%FinalScore.text = "You grabbed %d gems. Best: %d" % [score, best]
	_show_card(%GameOverCard)


func _show_card(card: Control) -> void:
	card.visible = true
	card.modulate.a = 0.0
	# The container lays the card out a frame later, and the pivot needs its size.
	await get_tree().process_frame
	card.pivot_offset = card.size / 2.0
	card.scale = Vector2(0.8, 0.8)
	var tween := create_tween().set_parallel()
	tween.tween_property(card, "scale", Vector2.ONE, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tween.tween_property(card, "modulate:a", 1.0, 0.15)


func _pop(control: Control, amount: float) -> void:
	control.pivot_offset = control.size / 2.0
	control.scale = Vector2(amount, amount)
	create_tween().tween_property(control, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _on_play_pressed() -> void:
	play_pressed.emit()


func _on_retry_pressed() -> void:
	retry_pressed.emit()
