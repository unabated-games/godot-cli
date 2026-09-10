#!/usr/bin/env python3
"""Generate src/godot/class_table.zig from Godot's class reference XML.

The XML ships in the engine repository under doc/classes/, one file per class,
each naming the class it inherits, its properties with their Variant types, and
its signals. That is everything `scene validate` needs to tell a wrong property
type or a misspelled signal from a right one, and users must not need an engine
checkout, so the table is generated here and committed.

    tools/gen_class_table.py ~/src/godot > src/godot/class_table.zig
    zig fmt src/godot/class_table.zig

Only classes that can appear in a scene or a resource file are kept (anything
descending from Node or Resource), which is about two thirds of them.
"""

import glob
import os
import sys
import xml.etree.ElementTree as ET

# Godot's own name for the type, as the XML writes it, mapped to the Variant
# kinds godot-cli parses a property value into. An empty tuple means "do not
# check": either the type is a class (a resource reference, checked by shape)
# or it is one godot-cli has no opinion about.
SCALAR_KINDS = {
    "bool": ("bool",),
    # A whole float is written `1` in a scene as often as `1.0`, and Godot
    # reads either, so an integer literal is a valid float.
    "float": ("float", "integer"),
    "int": ("integer",),
    "String": ("string",),
    "StringName": ("string", "string_name"),
    "NodePath": ("string", "node_path"),
    "Color": ("color",),
    "Vector2": ("vector2",),
    "Vector2i": ("vector2i",),
    "Vector3": ("vector3",),
    "Vector3i": ("vector3i",),
    "Vector4": ("vector4",),
    "Vector4i": ("vector4i",),
    "Rect2": ("rect2",),
    "Rect2i": ("rect2i",),
    "Plane": ("plane",),
    "Quaternion": ("quaternion",),
    "AABB": ("aabb",),
    "Transform2D": ("transform2d",),
    "Basis": ("basis",),
    "Transform3D": ("transform3d",),
    "Projection": ("projection",),
    "RID": ("rid",),
    "Callable": ("callable",),
    "Signal": ("signal",),
    "Array": ("array",),
    "Dictionary": ("dictionary",),
    # Every Packed*Array is documented as a class, so without these they fell
    # through to OBJECT_KINDS and validate demanded a resource reference where
    # the editor writes `PackedVector2Array(0, 0, 10, 10)`. Line2D.points,
    # Polygon2D.polygon and Gradient.offsets were errors on files Godot itself
    # saved. The parser reports one kind for all of them and carries the exact
    # type separately, so this checks the shape and not which packed type.
    "PackedByteArray": ("packed_array",),
    "PackedInt32Array": ("packed_array",),
    "PackedInt64Array": ("packed_array",),
    "PackedFloat32Array": ("packed_array",),
    "PackedFloat64Array": ("packed_array",),
    "PackedStringArray": ("packed_array",),
    "PackedVector2Array": ("packed_array",),
    "PackedVector3Array": ("packed_array",),
    "PackedVector4Array": ("packed_array",),
    "PackedColorArray": ("packed_array",),
}

# A property whose type is a class takes a resource reference or null.
OBJECT_KINDS = ("ext_resource", "sub_resource", "resource", "null")


def zig_string(text):
    return '"' + text.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main():
    if len(sys.argv) != 2:
        sys.exit("usage: gen_class_table.py <path to a godot source checkout>")
    root = sys.argv[1]
    class_dir = os.path.join(root, "doc", "classes")
    if not os.path.isdir(class_dir):
        sys.exit(f"no class reference at {class_dir}")

    # Modules and platforms carry their own doc_classes, and they are part of
    # the same class reference: CSG, GridMap, the audio streams, and since
    # 4.8 the whole tilemap family live there. Scanning only doc/classes left
    # every one of them out of the table, so `scene validate` skipped them in
    # silence -- and regenerating after tilemap moved would have dropped four
    # classes that had been there.
    paths = sorted(glob.glob(os.path.join(class_dir, "*.xml")))
    for extra in ("modules", "platform"):
        paths += sorted(glob.glob(os.path.join(root, extra, "*", "doc_classes", "*.xml")))

    classes = {}
    for path in paths:
        tree = ET.parse(path)
        node = tree.getroot()
        if node.tag != "class":
            continue
        members = node.find("members")
        signals = node.find("signals")
        classes[node.get("name")] = {
            "inherits": node.get("inherits") or "",
            "members": [
                (m.get("name"), m.get("type"))
                for m in (members if members is not None else [])
                if m.get("name") and m.get("type")
            ],
            "signals": sorted(
                s.get("name") for s in (signals if signals is not None else []) if s.get("name")
            ),
        }

    def descends_from(name, ancestor):
        seen = set()
        while name and name not in seen:
            if name == ancestor:
                return True
            seen.add(name)
            name = classes.get(name, {}).get("inherits")
        return False

    kept = sorted(
        name
        for name in classes
        if descends_from(name, "Node") or descends_from(name, "Resource")
    )

    version = "unknown"
    version_file = os.path.join(root, "version.py")
    if os.path.isfile(version_file):
        scope = {}
        with open(version_file) as handle:
            exec(handle.read(), scope)  # noqa: S102 - the engine's own version file
        version = f"{scope.get('major')}.{scope.get('minor')}.{scope.get('patch', 0)}"

    out = sys.stdout
    out.write(
        "//! Property and signal types for every Godot class that can appear in\n"
        "//! a scene or a resource file, so `scene validate` can tell a wrong\n"
        "//! property type from a right one.\n"
        "//!\n"
        "//! GENERATED by tools/gen_class_table.py from Godot's doc/classes XML.\n"
        f"//! Godot {version}. Do not edit; regenerate against a newer engine\n"
        "//! checkout instead, and commit the result.\n"
        "\n"
        "const std = @import(\"std\");\n"
        "\n"
        "pub const Property = struct {\n"
        "    name: []const u8,\n"
        "    /// Godot's own type name, for the failure message.\n"
        "    type_name: []const u8,\n"
        "    /// Variant kinds a value of this type may parse as; empty means\n"
        "    /// the type carries no check.\n"
        "    kinds: []const []const u8,\n"
        "};\n"
        "\n"
        "pub const Class = struct {\n"
        "    name: []const u8,\n"
        "    inherits: []const u8,\n"
        "    properties: []const Property,\n"
        "    signals: []const []const u8,\n"
        "};\n"
        "\n"
        f"pub const godot_version = \"{version}\";\n"
        "\n"
        "pub const classes = [_]Class{\n"
    )

    for name in kept:
        info = classes[name]
        out.write("    .{\n")
        out.write(f"        .name = {zig_string(name)},\n")
        out.write(f"        .inherits = {zig_string(info['inherits'])},\n")
        if info["members"]:
            out.write("        .properties = &.{\n")
            for prop_name, prop_type in sorted(info["members"]):
                if prop_type in SCALAR_KINDS:
                    kinds = SCALAR_KINDS[prop_type]
                elif prop_type in classes:
                    kinds = OBJECT_KINDS
                else:
                    # Typed arrays, enums spelled as a class, and anything a
                    # newer engine adds: recorded, not checked.
                    kinds = ()
                kind_text = ", ".join(zig_string(k) for k in kinds)
                out.write(
                    f"            .{{ .name = {zig_string(prop_name)}, "
                    f".type_name = {zig_string(prop_type)}, "
                    f".kinds = &.{{{kind_text}}} }},\n"
                )
            out.write("        },\n")
        else:
            out.write("        .properties = &.{},\n")
        if info["signals"]:
            names = ", ".join(zig_string(s) for s in info["signals"])
            out.write(f"        .signals = &.{{{names}}},\n")
        else:
            out.write("        .signals = &.{},\n")
        out.write("    },\n")

    out.write("};\n")
    sys.stderr.write(
        f"{len(kept)} classes, "
        f"{sum(len(classes[c]['members']) for c in kept)} properties, "
        f"{sum(len(classes[c]['signals']) for c in kept)} signals "
        f"(Godot {version})\n"
    )


if __name__ == "__main__":
    main()
