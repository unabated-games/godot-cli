//! Pointers into Godot engine source used as the source of truth for Variant text I/O.
//!
//! Repository: `godotengine/godot` (sibling checkout at `../godot` when developing locally).

pub const variant_parser_cpp = "core/variant/variant_parser.cpp";
pub const variant_parser_h = "core/variant/variant_parser.h";

/// `VariantParser::parse_value` — identifier constructors (Vector2, Color, …).
pub const parse_value_identifiers_line: u32 = 694;

/// `VariantParser::_parse_construct` — comma-separated numeric constructor args.
pub const parse_construct_line: u32 = 552;

/// `VariantParser::_parse_byte_array` — PackedByteArray base64 or byte list.
pub const parse_byte_array_line: u32 = 601;

/// Typed `Array[…]([…])` constructor.
pub const typed_array_line: u32 = 1328;

/// Typed `Dictionary[…, …]({…})` constructor.
pub const typed_dictionary_line: u32 = 1188;

/// `Resource` / `ExtResource` / `SubResource` reference parsing.
pub const resource_reference_line: u32 = 1090;

/// `VariantWriter::write` — serialization (`rtos_fix`, constructor formatting).
pub const variant_writer_line: u32 = 2012;

/// `rtos_fix` — float text normalization (0, inf_neg, f32 collapse).
pub const rtos_fix_line: u32 = 1986;

/// `stor_fix` — inf/nan identifiers inside constructor arg lists.
pub const stor_fix_line: u32 = 150;

/// `Object(ClassName, "prop": value, …)` parse/write.
pub const object_constructor_line: u32 = 995;
