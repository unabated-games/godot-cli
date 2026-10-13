//! The shape of a generated export option table (tools/gen_export_options.sh).

/// What an option's value is, as far as godot-cli needs to know to write
/// one from JSON. Taken from the editor's own property info where the option
/// was visible on a fresh preset, and otherwise from its default text.
pub const Kind = enum {
    bool,
    int,
    float,
    string,
    color,
    packed_string_array,
    dictionary,
    array,
    other,
};

pub const Choice = struct {
    /// What the editor shows (`Export AAB`, `arm64`).
    label: []const u8,
    /// The text written to the file for it (`1`, `"arm64"`).
    value: []const u8,
};

pub const Option = struct {
    name: []const u8,
    /// Exactly the text the editor writes for a fresh preset.
    default: []const u8,
    kind: Kind,
    /// Written to .godot/export_credentials.cfg, never export_presets.cfg.
    secret: bool = false,
    choices: []const Choice = &.{},
};

pub const Key = struct {
    name: []const u8,
    default: []const u8,
};

pub const Platform = struct {
    /// What a preset's `platform` key holds: `Windows Desktop`, not `Windows`.
    name: []const u8,
    /// `EditorExportPlatform.get_os_name()`: `Windows`, `macOS`.
    os_name: []const u8,
    /// Every option, in the order the editor writes them; secret ones last,
    /// in the order they go to the credentials file.
    options: []const Option,
};

pub const Table = struct {
    /// `4.8`: matched against a project's `config/features`.
    minor: []const u8,
    /// The full version string of the engine the table came from.
    godot_version: []const u8,
    /// The keys of a `[preset.N]` section, in the editor's order.
    preset_keys: []const Key,
    /// The keys of a `[preset.N]` section in the credentials file.
    credential_keys: []const Key,
    platforms: []const Platform,
};
