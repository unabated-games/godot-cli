extends Node
class_name VariantFixtureHolder

@export var meta_gradient: Gradient
@export var meta_array: Array[int] = [1, 2, 3]
@export var meta_dictionary: Dictionary[String, int] = { "a": 1, "count": 3 }
@export var meta_plain_array: Array = [1, 2, Vector3(1, 2, 3)]
@export var meta_plain_dictionary: Dictionary = { "enabled": true, "count": 3 }
@export var meta_packed_bytes: PackedByteArray = PackedByteArray([1, 2, 3])
@export var meta_color: Color = Color(1.0, 0.25, 0.5, 1.0)
