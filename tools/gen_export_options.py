#!/usr/bin/env python3
"""Turn an editor's full save of export presets into a Zig option table.

Run by tools/gen_export_options.sh, which has the editor write
export_presets.cfg and .godot/export_credentials.cfg with one preset per
platform, every option filled in, plus a JSON dump of what the editor says
about each visible option. This reads the three and prints Zig.

    gen_export_options.py <version> <presets.cfg> <credentials.cfg> <dump.json> <platform>...

The files are the authority for which options exist, their order and their
default text: that is exactly what the editor writes. The dump only adds
types and enum choices, and only for options visible on a fresh preset.
"""

import json
import re
import sys


def parse_config(text):
    """Godot ConfigFile text -> [(section, [(key, value_text)])], in order.

    A value runs to the end of its line unless a string or a bracket is still
    open: the editor writes multi-line strings (the default ssh run script)
    and multi-line dictionaries.
    """
    sections = []
    current = None
    i = 0
    n = len(text)
    while i < n:
        end = text.find("\n", i)
        if end == -1:
            end = n
        line = text[i:end].strip()
        if not line or line.startswith(";"):
            i = end + 1
            continue
        if line.startswith("["):
            current = (line[1 : line.rindex("]")], [])
            sections.append(current)
            i = end + 1
            continue
        eq = text.index("=", i)
        key = text[i:eq].strip()
        j = eq + 1
        depth = 0
        in_string = False
        while j < n:
            c = text[j]
            if in_string:
                if c == "\\":
                    j += 2
                    continue
                if c == '"':
                    in_string = False
            elif c == '"':
                in_string = True
            elif c in "([{":
                depth += 1
            elif c in ")]}":
                depth -= 1
            elif c == "\n" and depth == 0:
                break
            j += 1
        current[1].append((key, text[eq + 1 : j]))
        i = j + 1
    return sections


def zig_string(text):
    out = []
    for c in text:
        if c == "\\":
            out.append("\\\\")
        elif c == '"':
            out.append('\\"')
        elif c == "\n":
            out.append("\\n")
        elif c == "\t":
            out.append("\\t")
        else:
            out.append(c)
    return '"' + "".join(out) + '"'


KINDS = {
    "bool": "bool",
    "int": "int",
    "float": "float",
    "String": "string",
    "Color": "color",
    "PackedStringArray": "packed_string_array",
    "Dictionary": "dictionary",
    "Array": "array",
}


def infer_kind(default):
    if default in ("true", "false"):
        return "bool"
    if re.fullmatch(r"-?\d+", default):
        return "int"
    if re.fullmatch(r"-?\d+\.\d*(e[-+]?\d+)?", default):
        return "float"
    if default.startswith('"'):
        return "string"
    if default.startswith("Color("):
        return "color"
    if default.startswith("PackedStringArray("):
        return "packed_string_array"
    if default.startswith("{"):
        return "dictionary"
    if default.startswith("["):
        return "array"
    return "other"


def enum_choices(kind, hint_string):
    """PROPERTY_HINT_ENUM text -> [(label, value_text)].

    An int enum is "A,B,C" (values 0, 1, 2) or "A:4,B:8"; a string enum's
    items are the values themselves.
    """
    choices = []
    next_value = 0
    for item in hint_string.split(","):
        if kind == "int":
            if ":" in item:
                label, value = item.rsplit(":", 1)
                next_value = int(value)
            else:
                label = item
            choices.append((label, str(next_value)))
            next_value += 1
        elif kind == "string":
            choices.append((item, '"' + item.replace("\\", "\\\\").replace('"', '\\"') + '"'))
    return choices


def main():
    version, presets_path, credentials_path, dump_path = sys.argv[1:5]
    expected = sys.argv[5:]
    presets = parse_config(open(presets_path).read())
    credentials = dict(parse_config(open(credentials_path).read()))
    dump = json.load(open(dump_path))
    os_names = {name: os_name for os_name, name in dump["names"].items()}

    by_name = {}
    preset_keys = None
    credential_keys = None
    index = 0
    sections = dict(presets)
    while f"preset.{index}" in sections:
        main_entries = sections[f"preset.{index}"]
        values = dict(main_entries)
        platform = json.loads(values["platform"])
        if preset_keys is None:
            preset_keys = main_entries
            credential_keys = credentials.get(f"preset.{index}", [])
        options = [(k, v, False) for k, v in sections.get(f"preset.{index}.options", [])]
        options += [(k, v, True) for k, v in credentials.get(f"preset.{index}.options", [])]
        by_name[platform] = options
        index += 1

    missing = [p for p in expected if p not in by_name]
    if missing:
        sys.exit(f"the editor dropped preset(s) for {missing}: not a platform this build knows")

    match = re.match(r"(\d+)\.(\d+)", version)
    minor = f"{match.group(1)}.{match.group(2)}" if match else version

    out = sys.stdout
    out.write(
        "//! Every export option Godot's editor writes for each platform, in the\n"
        "//! order it writes them, with the default text it writes.\n"
        "//!\n"
        "//! GENERATED by tools/gen_export_options.sh from the editor's own save.\n"
        f"//! {version}. Do not edit; regenerate against that engine instead.\n"
        "\n"
        'const types = @import("types.zig");\n'
        "\n"
        "pub const table = types.Table{\n"
        f"    .minor = {zig_string(minor)},\n"
        f"    .godot_version = {zig_string(version)},\n"
        "    .preset_keys = &.{\n"
    )
    for key, value in preset_keys:
        if key in ("name", "platform"):
            value = '""'
        out.write(f"        .{{ .name = {zig_string(key)}, .default = {zig_string(value)} }},\n")
    out.write("    },\n    .credential_keys = &.{\n")
    for key, value in credential_keys:
        out.write(f"        .{{ .name = {zig_string(key)}, .default = {zig_string(value)} }},\n")
    out.write("    },\n    .platforms = &.{\n")
    for platform in expected:
        os_name = os_names.get(platform, platform)
        info = dump["platforms"].get(os_name, {})
        out.write("        .{\n")
        out.write(f"            .name = {zig_string(platform)},\n")
        out.write(f"            .os_name = {zig_string(os_name)},\n")
        out.write("            .options = &.{\n")
        for key, default, secret in by_name[platform]:
            prop = info.get(key, {})
            kind = KINDS.get(prop.get("type", ""), None) or infer_kind(default)
            fields = [
                f".name = {zig_string(key)}",
                f".default = {zig_string(default)}",
                f".kind = .{kind}",
            ]
            if secret:
                fields.append(".secret = true")
            if prop.get("enum"):
                choices = enum_choices(kind, prop.get("hint_string", ""))
                if choices:
                    rendered = ", ".join(
                        f".{{ .label = {zig_string(label)}, .value = {zig_string(value)} }}" for label, value in choices
                    )
                    fields.append(f".choices = &.{{{rendered}}}")
            out.write("                .{ " + ", ".join(fields) + " },\n")
        out.write("            },\n        },\n")
    out.write("    },\n};\n")

    total = sum(len(v) for v in by_name.values())
    sys.stderr.write(f"{len(expected)} platforms, {total} options (Godot {version})\n")


if __name__ == "__main__":
    main()
