@tool
extends MarginContainer

signal button_pressed

@export var label_text : String = "Label Text" :
	set(value):
		label_text = value
		var n = get_node_or_null("Label")
		if n:
			n.text = label_text

var u : float = 1.0
