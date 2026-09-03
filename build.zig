const std = @import("std");

// Although this function looks imperative, it does not perform the build
// directly and instead it mutates the build graph (`b`) that will be then
// executed by an external runner. The functions in `std.Build` implement a DSL
// for defining build steps and express dependencies between them, allowing the
// build runner to parallelize the build automatically (and the cache system to
// know when a step doesn't need to be re-run).
pub fn build(b: *std.Build) void {
    // Standard target options allow the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});
    // Standard optimization options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall. Here we do not
    // set a preferred release mode, allowing the user to decide how to optimize.
    const optimize = b.standardOptimizeOption(.{});

    const version_string = b.option([]const u8, "version-string", "Version string embedded in the CLI") orelse "0.12.0";
    // Release date of `version_string`, shown in the man page header. Bumped
    // with the version at release time (see RELEASING.md) rather than read
    // from the clock, so the generated docs stay byte-stable.
    const version_date = b.option([]const u8, "version-date", "Release date (YYYY-MM-DD) of the embedded version") orelse "2026-09-04";

    const version_options = b.addOptions();
    version_options.addOption([]const u8, "version", version_string);
    version_options.addOption([]const u8, "version_date", version_date);
    version_options.addOption([]const u8, "templates_root", "templates");

    // This creates a module, which represents a collection of source files alongside
    // some compilation options, such as optimization mode and linked system libraries.
    // Zig modules are the preferred way of making Zig code available to consumers.
    // addModule defines a module that we intend to make available for importing
    // to our consumers. We must give it a name because a Zig package can expose
    // multiple modules and consumers will need to be able to specify which
    // module they want to access.
    const mod = b.addModule("godot_cli_tools", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .imports = &.{
            .{ .name = "build_options", .module = version_options.createModule() },
        },
    });

    // Here we define an executable. An executable needs to have a root module
    // which needs to expose a `main` function. While we could add a main function
    // to the module defined above, it's sometimes preferable to split business
    // logic and the CLI into two separate modules.
    //
    // If your goal is to create a Zig library for others to use, consider if
    // it might benefit from also exposing a CLI tool. A parser library for a
    // data serialization format could also bundle a CLI syntax checker, for example.
    //
    // If instead your goal is to create an executable, consider if users might
    // be interested in also being able to embed the core functionality of your
    // program in their own executable in order to avoid the overhead involved in
    // subprocessing your CLI tool.
    //
    // If neither case applies to you, feel free to delete the declaration you
    // don't need and to put everything under a single module.
    const exe = b.addExecutable(.{
        .name = "godot-cli",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "godot_cli_tools", .module = mod },
                .{ .name = "build_options", .module = version_options.createModule() },
            },
        }),
    });

    // This declares intent for the executable to be installed into the
    // install prefix when running `zig build` (i.e. when executing the default
    // step). By default the install prefix is `zig-out/` but can be overridden
    // by passing `--prefix` or `-p`.
    // The MCP server embeds the agent docs and example intents as resources.
    // Each file is an anonymous import so `@embedFile` can reach outside src/.
    const embedded_files = [_]struct { name: []const u8, path: []const u8 }{
        .{ .name = "doc_quickstart", .path = "docs/agent_quickstart.md" },
        .{ .name = "doc_godot_basics", .path = "docs/agent_godot_basics.md" },
        .{ .name = "doc_scene_authoring", .path = "docs/agent_scene_authoring.md" },
        .{ .name = "doc_batch_commands", .path = "docs/agent_batch_commands.md" },
        .{ .name = "doc_commands", .path = "docs/commands.md" },
        .{ .name = "doc_mcp_tools", .path = "docs/mcp_tools.json" },
        .{ .name = "default_project_icon", .path = "share/default_project_icon.svg" },
        .{ .name = "example_assign_sprite_texture", .path = "share/examples/intents/assign_sprite_texture.json" },
        .{ .name = "example_autoload_game_state", .path = "share/examples/intents/autoload_game_state.json" },
        .{ .name = "example_catalog_button", .path = "share/examples/intents/catalog_button.json" },
        .{ .name = "example_display_stretch", .path = "share/examples/intents/display_stretch.json" },
        .{ .name = "example_enable_sample_plugin", .path = "share/examples/intents/enable_sample_plugin.json" },
        .{ .name = "example_hud_main", .path = "share/examples/intents/hud_main.json" },
        .{ .name = "example_hud_top_bar", .path = "share/examples/intents/hud_top_bar.json" },
        .{ .name = "example_main_scene", .path = "share/examples/intents/main_scene.json" },
        .{ .name = "example_physics_jolt", .path = "share/examples/intents/physics_jolt.json" },
        .{ .name = "example_physics_layers", .path = "share/examples/intents/physics_layers.json" },
        .{ .name = "example_player_with_icon", .path = "share/examples/intents/player_with_icon.json" },
        .{ .name = "example_project_bootstrap", .path = "share/examples/intents/project_bootstrap.json" },
        .{ .name = "example_rendering_forward_plus", .path = "share/examples/intents/rendering_forward_plus.json" },
        .{ .name = "example_wasd_movement", .path = "share/examples/intents/wasd_movement.json" },
        .{ .name = "example_sprite_icon_texture", .path = "share/examples/patches/sprite_icon_texture.json" },
    };
    for (embedded_files) |file| {
        mod.addAnonymousImport(file.name, .{ .root_source_file = b.path(file.path) });
        exe.root_module.addAnonymousImport(file.name, .{ .root_source_file = b.path(file.path) });
    }

    b.installArtifact(exe);

    // This creates a top level step. Top level steps have a name and can be
    // invoked by name when running `zig build` (e.g. `zig build run`).
    // This will evaluate the `run` step rather than the default step.
    // For a top level step to actually do something, it must depend on other
    // steps (e.g. a Run step, as we will see in a moment).
    const run_step = b.step("run", "Run the app");

    // This creates a RunArtifact step in the build graph. A RunArtifact step
    // invokes an executable compiled by Zig. Steps will only be executed by the
    // runner if invoked directly by the user (in the case of top level steps)
    // or if another step depends on it, so it's up to you to define when and
    // how this Run step will be executed. In our case we want to run it when
    // the user runs `zig build run`, so we create a dependency link.
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);

    // By making the run step depend on the default step, it will be run from the
    // installation directory rather than directly from within the cache directory.
    run_cmd.step.dependOn(b.getInstallStep());

    // This allows the user to pass arguments to the application in the build
    // command itself, like this: `zig build run -- arg1 arg2 etc`
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Creates an executable that will run `test` blocks from the provided module.
    // Here `mod` needs to define a target, which is why earlier we made sure to
    // set the releative field.
    const mod_tests = b.addTest(.{
        .root_module = mod,
    });

    // A run step that will run the test executable.
    const run_mod_tests = b.addRunArtifact(mod_tests);

    // Creates an executable that will run `test` blocks from the executable's
    // root module. Note that test executables only test one module at a time,
    // hence why we have to create two separate ones.
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });

    // A run step that will run the second test executable.
    const run_exe_tests = b.addRunArtifact(exe_tests);

    // A top level step for running all tests. dependOn can be called multiple
    // times and since the two run steps do not depend on one another, this will
    // make the two of them run in parallel.
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mod_tests.step);
    test_step.dependOn(&run_exe_tests.step);

    // The MCP server over a real pipe: both protocol openings, a tool call,
    // a confined path, resources, and the prompt.
    const mcp_smoke = b.addSystemCommand(&.{ "bash", "tools/test_mcp.sh" });
    mcp_smoke.setCwd(b.path("."));
    mcp_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&mcp_smoke.step);

    // Trial 9 and 10 fixes: inline intents, unique_name surviving a
    // properties object, project new, --properties, and the freed-memory
    // path through the in-process invoke that set-property tripped.
    const batch_fixes_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"add_node","parent":"/root/Root","name":"Score","type":"Label","unique_name":true,"properties":{"visible":false}}]}' --json) &&
        \\echo "$out" | grep -q 'unique_name_in_owner' && echo "$out" | grep -q '"intent":"inline"' &&
        \\t=$(mktemp -d) &&
        \\./zig-out/bin/godot-cli scene new --output "$t/main.tscn" --root-name Main --root-type Node2D --json >/dev/null &&
        \\./zig-out/bin/godot-cli scene plan "$t/main.tscn" --intent share/examples/intents/hud_top_bar.json --json >/dev/null &&
        \\./zig-out/bin/godot-cli project new --project-root "$t" --name Smoke --main-scene res://main.tscn --width 640 --height 360 --json | grep -q '"ok":true' &&
        \\grep -q 'config/name="Smoke"' "$t/project.godot" && grep -q 'viewport_height=360' "$t/project.godot" &&
        \\./zig-out/bin/godot-cli project show --project-root "$t" --json | grep -q '"ok":true' &&
        \\! ./zig-out/bin/godot-cli project new --project-root "$t" --name Again --json >/dev/null &&
        \\./zig-out/bin/godot-cli project show --project-root "$t/nope" --json | grep -q 'create one with' &&
        \\./zig-out/bin/godot-cli project settings apply --project-root "$t" --intent-json '{"application":{"config/description":"hi there"}}' --json | grep -q '"ok":true' && grep -q 'config/description="hi there"' "$t/project.godot" &&
        \\./zig-out/bin/godot-cli scene node add "$t/main.tscn" --parent /root/Main --name Box --type Node2D --properties '{"visible":false,"position":"Vector2(1, 2)","z_index":3}' --json | grep -q '"ok":true' &&
        \\grep -q 'z_index = 3' "$t/main.tscn" && grep -q 'position = Vector2(1, 2)' "$t/main.tscn" &&
        \\out=$(./zig-out/bin/godot-cli batch --json-body "{\"steps\":[{\"argv\":[\"scene\",\"set-property\",\"$t/main.tscn\",\"--node\",\"/root/Main/Box\",\"--property\",\"z_index\",\"--value\",\"4\",\"--json\"]}]}" --json) &&
        \\echo "$out" | grep -q '"property":"z_index"' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"teleport","parent":"/root/Main","name":"X"}]}' --json | grep -q '"kind":"unknown_recipe"' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"camera_2d","parent":"/root/Main","name":"Cam"},{"recipe":"assign_ext","path":"/root/Main","property":"script"}]}' --json | grep -q '"step":1' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"assign_ext","path":"/root/Main","property":"script","res_path":"res://scripts/main.gd"}]}' --json | grep -q '\\"ext_type\\": \\"Script\\"' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"camera_2d","parent":"/root/Main","name":"Cam","position":"Vector2(320, 180)"}]}' --json | grep -q 'Vector2(320, 180)' &&
        \\./zig-out/bin/godot-cli scene apply "$t/main.tscn" --intent-json '{"steps":[{"recipe":"add_node","parent":"/root/Main","name":"HUD","type":"CanvasLayer"},{"recipe":"add_node","parent":"/root/Main/HUD","name":"Score","type":"Label","properties":{"text":"\"0\"","offset_left":8.0}},{"recipe":"add_node","parent":"/root/Main/HUD","name":"Go","type":"Button"},{"recipe":"connect","from":"/root/Main/HUD/Go","signal":"pressed","to":"/root/Main/HUD","method":"_on_go"},{"recipe":"connect","from":"/root/Main/HUD/Go","signal":"pressed","to":"/root/Main","method":"_on_main_go"}]}' --project-root "$t" --json | grep -q '"ok":true' &&
        \\out=$(./zig-out/bin/godot-cli scene extract "$t/main.tscn" /root/Main/HUD --output ui/hud.tscn --project-root "$t" --json) &&
        \\echo "$out" | grep -q '"moved_nodes":3' && echo "$out" | grep -q '"moved_connections":1' && echo "$out" | grep -q 'crossed the boundary' &&
        \\grep -q 'name="Score" type="Label" parent="."' "$t/ui/hud.tscn" && grep -q 'from="Go" to="."' "$t/ui/hud.tscn" && grep -q 'offset_left = 8.0' "$t/ui/hud.tscn" &&
        \\grep -q 'name="HUD" parent="." instance=ExtResource' "$t/main.tscn" && ! grep -q 'name="Score"' "$t/main.tscn" &&
        \\./zig-out/bin/godot-cli scene validate "$t/ui/hud.tscn" --project-root "$t" --json | grep -q '"ok":true' &&
        \\./zig-out/bin/godot-cli scene validate "$t/main.tscn" --project-root "$t" --json | grep -q '"ok":true' &&
        \\./zig-out/bin/godot-cli scene node get "$t/ui/hud.tscn" /root/HUD/Score --json | grep -q '"properties"' &&
        \\out=$(./zig-out/bin/godot-cli scene apply "$t/main.tscn" --patch-json '{"ops":[{"op":"node_remove","path":"/root/Main/HUD","recursive":true}]}' --write-undo-patch "$t/undo.json" --project-root "$t" --json) &&
        \\echo "$out" | grep -q '"ok":true' && grep -q '"instance_add"' "$t/undo.json" && grep -q '"scene": "res://ui/hud.tscn"' "$t/undo.json" &&
        \\./zig-out/bin/godot-cli scene apply "$t/main.tscn" --patch-json '{"ops":[{"op":"add_node","parent":"/root/Main","name":"Menu","type":"Control"},{"op":"teleport"}]}' --project-root "$t" --json | grep -q '"kind":"unknown_patch_op"' &&
        \\./zig-out/bin/godot-cli scene apply "$t/main.tscn" --patch-json '{"ops":[{"op":"add_node","parent":"/root/Main","name":"Menu","type":"Control"}]}' --project-root "$t" --json | grep -q '"ok":true' &&
        \\./zig-out/bin/godot-cli scene validate "$t/main.tscn" --project-root "$t" --json | grep -q 'control_under_node2d' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"node_set","path":"/root/Main/Menu","property":"offset_left","value":15}]}' --json | grep -q '15.0' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"node_set","path":"/root/Main/Menu","property":"visible","value":[1]}]}' --json | grep -q '"kind":"invalid_intent"' &&
        \\out=$(./zig-out/bin/godot-cli scene extract "$t/main.tscn" /root/Main/Menu --output ui/menu.tscn --catalog-id ui/menu --project-root "$t" --json) &&
        \\echo "$out" | grep -q '"catalog_registered":true' && test -f "$t/ui/menu.manifest.json" &&
        \\! ./zig-out/bin/godot-cli project new --project-root "$t/n" --name N --width abc --json >/dev/null 2>&1 &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"instance_catalog","parent":"/root/Root","name":"Btn","catalog_id":"ui/button","properties":{"visible":false}}]}' --project-root test_fixtures/project --json | grep -q 'visible' &&
        \\./zig-out/bin/godot-cli scene instance add "$t/main.tscn" --parent /root/Main --name Btn --scene res://main.tscn --properties '{"visible":false}' --project-root "$t" --json | grep -q '"ok":true' &&
        \\grep -q 'visible = false' "$t/main.tscn" &&
        \\./zig-out/bin/godot-cli scene node add "$t/main.tscn" --parent /root/Main --name Bad --type Label --properties '{"text":"bare"}' --dry-run --json | grep -q '"field":"text"' &&
        \\./zig-out/bin/godot-cli scene node list "$t/main.tscn" --json | grep -q '"type":"PackedScene"' &&
        \\./zig-out/bin/godot-cli scene recipes --json | grep -q '"name":"static_body_2d"' &&
        \\./zig-out/bin/godot-cli scene plan --intent-json '{"steps":[{"recipe":"static_body_2d","parent":"/root/Main","name":"Floor","size":"Vector2(200, 20)","color":"Color(0.3, 0.5, 0.8, 1)"}]}' --json | grep -q 'PackedVector2Array(-100, -10, 100, -10, 100, 10, -100, 10)' &&
        \\test -s "$t/icon.svg" &&
        \\./zig-out/bin/godot-cli project show --project-root "$t" --json | grep -q '"viewport_width":"640"' &&
        \\head -1 "$t/main.tscn" | grep -q 'uid="uid://' &&
        \\./zig-out/bin/godot-cli resource new --output "$t/box.tres" --type StyleBoxFlat --json | grep -q '"uid":"uid://' &&
        \\./zig-out/bin/godot-cli scene validate "$t/box.tres" --json | grep -q '"kind":"resource"' &&
        \\./zig-out/bin/godot-cli scene node add "$t/main.tscn" --parent /root/Main --name Lbl --type Label --properties '{"offset_left":8,"z_index":2}' --json >/dev/null &&
        \\grep -q 'offset_left = 8.0' "$t/main.tscn" && grep -q 'z_index = 2' "$t/main.tscn" &&
        \\rm -rf "$t"
    });
    batch_fixes_smoke.setCwd(b.path("."));
    batch_fixes_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&batch_fixes_smoke.step);

    const inspect_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene inspect test_fixtures/project/sample.tscn --json --no-validate) &&
        \\echo "$out" | grep -q '"properties"' &&
        \\echo "$out" | grep -q '"kind":"bool"'
    });
    inspect_smoke.setCwd(b.path("."));
    inspect_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&inspect_smoke.step);

    const node_list_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene node list test_fixtures/project/sample.tscn --json) &&
        \\echo "$out" | grep -q '"nodes"' &&
        \\echo "$out" | grep -q '"/root/Root/Collision"' &&
        \\out2=$(./zig-out/bin/godot-cli scene node list test_fixtures/project/sample.tscn --project-root test_fixtures/project --json) &&
        \\echo "$out2" | grep -q '"nodes"'
    });
    node_list_smoke.setCwd(b.path("."));
    node_list_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&node_list_smoke.step);

    const scene_author_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp /tmp/godot_cli_scene_XXXXXX.tscn) &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp" --root-name Main --root-type Node2D --no-prepare-save &&
        \\./zig-out/bin/godot-cli scene node add "$tmp" --parent /root/Main --name Player --type CharacterBody2D --no-prepare-save &&
        \\subout=$(./zig-out/bin/godot-cli scene sub add "$tmp" --type RectangleShape2D --property size --value "Vector2(16, 32)" --no-prepare-save --json) &&
        \\subid=$(echo "$subout" | grep -o '"id":"[^"]*"' | head -1 | cut -d'"' -f4) &&
        \\./zig-out/bin/godot-cli scene node add "$tmp" --parent /root/Main/Player --name Collision --type CollisionShape2D --property shape --value "SubResource(\"$subid\")" --no-prepare-save &&
        \\out=$(./zig-out/bin/godot-cli scene node list "$tmp" --json) &&
        \\rm -f "$tmp" &&
        \\echo "$out" | grep -q '"/root/Main/Player/Collision"'
    });
    scene_author_smoke.setCwd(b.path("."));
    scene_author_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_author_smoke.step);

    const scene_instance_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp) &&
        \\cp test_fixtures/project/test.tscn "$tmp" &&
        \\./zig-out/bin/godot-cli scene instance add "$tmp" --parent /root/Root --name MyButton --scene res://ui/button/button.tscn --project-root test_fixtures/project --no-prepare-save &&
        \\./zig-out/bin/godot-cli scene instance add "$tmp" --parent /root/Root --name CatalogButton --catalog-id ui/button --project-root test_fixtures/project --no-prepare-save &&
        \\grep -q 'instance=ExtResource' "$tmp" &&
        \\grep -q 'res://ui/button/button.tscn' "$tmp" &&
        \\rm -f "$tmp"
    });
    scene_instance_smoke.setCwd(b.path("."));
    scene_instance_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_instance_smoke.step);

    const scene_apply_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp) &&
        \\cp test_fixtures/project/test.tscn "$tmp" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp" --patch test_fixtures/project/patches/player_collision.json --project-root test_fixtures/project --no-prepare-save &&
        \\./zig-out/bin/godot-cli scene node list "$tmp" --json | grep -q '/root/Root/Player/Collision' &&
        \\rm -f "$tmp"
    });
    scene_apply_smoke.setCwd(b.path("."));
    scene_apply_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_apply_smoke.step);

    const scene_plan_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene plan test_fixtures/project/test.tscn \
        \\  --intent test_fixtures/project/intents/hud_player.json \
        \\  --project-root test_fixtures/project --json) &&
        \\echo "$out" | grep -q '"recipe":"player_2d"' &&
        \\echo "$out" | grep -q '"op":"node_add"' &&
        \\echo "$out" | grep -q '"op_count":'
    });
    scene_plan_smoke.setCwd(b.path("."));
    scene_plan_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_plan_smoke.step);

    const scene_plan_catalog_button_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene plan test_fixtures/project/test.tscn \
        \\  --intent test_fixtures/project/intents/start_button_label.json \
        \\  --project-root test_fixtures/project --json) &&
        \\echo "$out" | grep -q '"recipe":"catalog_button"' &&
        \\echo "$out" | grep -q 'instance_override' &&
        \\echo "$out" | grep -q 'Start Game'
    });
    scene_plan_catalog_button_smoke.setCwd(b.path("."));
    scene_plan_catalog_button_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_plan_catalog_button_smoke.step);

    const scene_player_texture_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp /tmp/godot_cli_player_tex.XXXXXX) &&
        \\tmp="${tmp}.tscn" &&
        \\mv "${tmp%.tscn}" "$tmp" &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp" --root-name Main --root-type Node2D --no-prepare-save &&
        \\./zig-out/bin/godot-cli scene apply "$tmp" \
        \\  --intent share/examples/intents/player_with_icon.json \
        \\  --project-root test_fixtures/project --no-prepare-save &&
        \\grep -q 'Texture2D_icon' "$tmp" &&
        \\grep -q 'texture = ExtResource("Texture2D_icon")' "$tmp" &&
        \\ext_line=$(grep -nF '[ext_resource' "$tmp" | head -1 | cut -d: -f1) &&
        \\sub_line=$(grep -nF '[sub_resource' "$tmp" | head -1 | cut -d: -f1) &&
        \\test -n "$ext_line" -a -n "$sub_line" -a "$ext_line" -lt "$sub_line" &&
        \\rm -f "$tmp"
    });
    scene_player_texture_smoke.setCwd(b.path("."));
    scene_player_texture_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_player_texture_smoke.step);

    const scene_apply_intent_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp) &&
        \\cp test_fixtures/project/test.tscn "$tmp" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp" \
        \\  --intent test_fixtures/project/intents/hud_player.json \
        \\  --project-root test_fixtures/project --no-prepare-save &&
        \\./zig-out/bin/godot-cli scene node list "$tmp" --json | grep -q '/root/Root/Player' &&
        \\rm -f "$tmp"
    });
    scene_apply_intent_smoke.setCwd(b.path("."));
    scene_apply_intent_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_apply_intent_smoke.step);

    const scene_diff_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene diff test_fixtures/project/test.tscn test_fixtures/project/sample.tscn --properties --json) &&
        \\echo "$out" | grep -q '"diff_count":' &&
        \\echo "$out" | grep -q '"property_diff_count":'
    });
    scene_diff_smoke.setCwd(b.path("."));
    scene_diff_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_diff_smoke.step);

    const scene_undo_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp) &&
        \\snap=$(mktemp) &&
        \\undo=$(mktemp) &&
        \\cp test_fixtures/project/test.tscn "$tmp" &&
        \\cp test_fixtures/project/test.tscn "$snap" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp" \
        \\  --patch test_fixtures/project/patches/player_collision.json \
        \\  --project-root test_fixtures/project --write-undo-patch "$undo" --no-prepare-save &&
        \\./zig-out/bin/godot-cli scene node list "$tmp" --json | grep -q '/root/Root/Player' &&
        \\grep -q 'node_remove' "$undo" &&
        \\./zig-out/bin/godot-cli scene restore "$tmp" --from "$snap" &&
        \\! ./zig-out/bin/godot-cli scene node list "$tmp" --json | grep -q '/root/Root/Player' &&
        \\rm -f "$tmp" "$snap" "$undo"
    });
    scene_undo_smoke.setCwd(b.path("."));
    scene_undo_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_undo_smoke.step);

    const scene_apply_dry_run_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene apply test_fixtures/project/test.tscn \
        \\  --patch test_fixtures/project/patches/player_collision.json \
        \\  --project-root test_fixtures/project --dry-run --json) &&
        \\echo "$out" | grep -q '"preview_diff":' &&
        \\echo "$out" | grep -q '"node_diff_count":'
    });
    scene_apply_dry_run_smoke.setCwd(b.path("."));
    scene_apply_dry_run_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_apply_dry_run_smoke.step);

    const scene_template_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp /tmp/godot_cli_template.XXXXXX) &&
        \\out=$(./zig-out/bin/godot-cli scene template show 2d/character_body --json) &&
        \\echo "$out" | grep -q '"node_count":' &&
        \\echo "$out" | grep -q '/root/Player' &&
        \\./zig-out/bin/godot-cli scene template copy 2d/character_body --output "$tmp" \
        \\  --rename-node Player:Hero --set-property '/root/Hero/visible=false' --no-prepare-save &&
        \\grep -q 'CharacterBody2D' "$tmp" &&
        \\grep -q 'visible = false' "$tmp" &&
        \\grep -q 'name="Hero"' "$tmp" &&
        \\rm -f "$tmp"
    });
    scene_template_smoke.setCwd(b.path("."));
    scene_template_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_template_smoke.step);

    const batch_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli batch --file test_fixtures/batch/ping_twice.json --json) &&
        \\echo "$out" | grep -q '"succeeded_count":2' &&
        \\echo "$out" | grep -q '"step_count":2'
    });
    batch_smoke.setCwd(b.path("."));
    batch_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&batch_smoke.step);

    const rich_inspect_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene inspect test_fixtures/project/rich_variants.tscn --json --no-validate) &&
        \\echo "$out" | grep -q '"kind":"object"' &&
        \\echo "$out" | grep -q '"kind":"typed_array"' &&
        \\echo "$out" | grep -q '"kind":"packed_array"'
    });
    rich_inspect_smoke.setCwd(b.path("."));
    rich_inspect_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&rich_inspect_smoke.step);

    const catalog_scan_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli catalog scan --project-root test_fixtures/project --json) &&
        \\echo "$out" | grep -q '"id":"ui/button"' &&
        \\echo "$out" | grep -q '"valid":true' &&
        \\echo "$out" | grep -q 'button_pressed'
    });
    catalog_scan_smoke.setCwd(b.path("."));
    catalog_scan_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_scan_smoke.step);

    const catalog_show_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli catalog show ui/button --project-root test_fixtures/project --json) &&
        \\echo "$out" | grep -q '"exports_source":"gdscript_heuristic"' &&
        \\echo "$out" | grep -q 'label_text' &&
        \\echo "$out" | grep -q 'button_pressed'
    });
    catalog_show_smoke.setCwd(b.path("."));
    catalog_show_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_show_smoke.step);

    const catalog_builtin_show_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli catalog show godot/ui/Button --json) &&
        \\echo "$out" | grep -q '"source":"builtin"' &&
        \\echo "$out" | grep -q '"class_name":"Button"'
    });
    catalog_builtin_show_smoke.setCwd(b.path("."));
    catalog_builtin_show_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_builtin_show_smoke.step);

    const catalog_validate_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\./zig-out/bin/godot-cli catalog validate --project-root test_fixtures/project --json | grep -q '"valid":true'
    });
    catalog_validate_smoke.setCwd(b.path("."));
    catalog_validate_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_validate_smoke.step);

    const catalog_search_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli catalog search --project-root test_fixtures/project --tags ui,button --json) &&
        \\echo "$out" | grep -q '"id":"ui/button"'
    });
    catalog_search_smoke.setCwd(b.path("."));
    catalog_search_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_search_smoke.step);

    const catalog_export_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli catalog export --project-root test_fixtures/project --output .catalog_export_smoke.md --json) &&
        \\echo "$out" | grep -q '"wrote_file":true' &&
        \\grep -q 'ui/button' test_fixtures/project/.catalog_export_smoke.md &&
        \\rm -f test_fixtures/project/.catalog_export_smoke.md
    });
    catalog_export_smoke.setCwd(b.path("."));
    catalog_export_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_export_smoke.step);

    const project_input_apply_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli project input apply --project-root test_fixtures/project --intent share/examples/intents/wasd_movement.json --dry-run --json) &&
        \\echo "$out" | grep -q 'move_left' &&
        \\echo "$out" | grep -q '"added_count":4'
    });
    project_input_apply_smoke.setCwd(b.path("."));
    project_input_apply_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_input_apply_smoke.step);

    const project_input_list_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/input_map_snippet.godot "$tmp/project.godot" &&
        \\out=$(./zig-out/bin/godot-cli project input list --project-root "$tmp" --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q '"action_count":2' &&
        \\echo "$out" | grep -q 'move_left'
    });
    project_input_list_smoke.setCwd(b.path("."));
    project_input_list_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_input_list_smoke.step);

    const project_settings_apply_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/project.godot "$tmp/project.godot" &&
        \\out=$(./zig-out/bin/godot-cli project settings apply --project-root "$tmp" --intent share/examples/intents/main_scene.json --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q 'run/main_scene' &&
        \\echo "$out" | grep -q '"added_count":1'
    });
    project_settings_apply_smoke.setCwd(b.path("."));
    project_settings_apply_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_settings_apply_smoke.step);

    const project_autoload_list_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/autoload_snippet.godot "$tmp/project.godot" &&
        \\out=$(./zig-out/bin/godot-cli project autoload list --project-root "$tmp" --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q '"autoload_count":2' &&
        \\echo "$out" | grep -q 'GameState'
    });
    project_autoload_list_smoke.setCwd(b.path("."));
    project_autoload_list_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_autoload_list_smoke.step);

    const project_plugins_enable_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/project.godot "$tmp/project.godot" &&
        \\cp -R test_fixtures/project/addons "$tmp/addons" &&
        \\out=$(./zig-out/bin/godot-cli project plugins enable --project-root "$tmp" --plugin sample_plugin --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q '"enabled":true'
    });
    project_plugins_enable_smoke.setCwd(b.path("."));
    project_plugins_enable_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_plugins_enable_smoke.step);

    const project_rendering_apply_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/project.godot "$tmp/project.godot" &&
        \\out=$(./zig-out/bin/godot-cli project rendering apply --project-root "$tmp" --intent share/examples/intents/rendering_forward_plus.json --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q 'renderer/rendering_method' &&
        \\echo "$out" | grep -q '"added_count":3'
    });
    project_rendering_apply_smoke.setCwd(b.path("."));
    project_rendering_apply_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_rendering_apply_smoke.step);

    const project_physics_apply_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/project.godot "$tmp/project.godot" &&
        \\out=$(./zig-out/bin/godot-cli project physics apply --project-root "$tmp" --intent share/examples/intents/physics_jolt.json --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q 'physics/3d/physics_engine' &&
        \\echo "$out" | grep -q '"added_count":2'
    });
    project_physics_apply_smoke.setCwd(b.path("."));
    project_physics_apply_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_physics_apply_smoke.step);

    const project_show_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli project show --project-root test_fixtures/project --json) &&
        \\echo "$out" | grep -q '"input_action_count"' &&
        \\echo "$out" | grep -q 'project summary'
    });
    project_show_smoke.setCwd(b.path("."));
    project_show_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_show_smoke.step);

    const project_apply_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\cp test_fixtures/project/project.godot "$tmp/project.godot" &&
        \\out=$(./zig-out/bin/godot-cli project apply --project-root "$tmp" --intent share/examples/intents/project_bootstrap.json --dry-run --json) &&
        \\rm -rf "$tmp" &&
        \\echo "$out" | grep -q '"section_count":5' &&
        \\echo "$out" | grep -q 'input'
    });
    project_apply_smoke.setCwd(b.path("."));
    project_apply_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_apply_smoke.step);

    const scene_unique_name_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp) &&
        \\cp test_fixtures/project/test.tscn "$tmp" &&
        \\./zig-out/bin/godot-cli scene set-property "$tmp" --node-name Root --property unique_name_in_owner --value true --json >/dev/null &&
        \\grep -q 'unique_name_in_owner = true' "$tmp" &&
        \\rm "$tmp"
    });
    scene_unique_name_smoke.setCwd(b.path("."));
    scene_unique_name_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&scene_unique_name_smoke.step);

    const node_order_validate_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli scene validate test_fixtures/project/bad_node_order.tscn --json || true) &&
        \\echo "$out" | grep -q 'node_parent_order'
    });
    node_order_validate_smoke.setCwd(b.path("."));
    node_order_validate_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&node_order_validate_smoke.step);

    const node_order_normalize_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp) &&
        \\cp test_fixtures/project/bad_node_order.tscn "$tmp" &&
        \\./zig-out/bin/godot-cli scene normalize "$tmp" --json >/dev/null &&
        \\out=$(./zig-out/bin/godot-cli scene validate "$tmp" --json) &&
        \\rm "$tmp" &&
        \\echo "$out" | grep -q '"error_count":0'
    });
    node_order_normalize_smoke.setCwd(b.path("."));
    node_order_normalize_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&node_order_normalize_smoke.step);

    const material_inspect_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli resource inspect test_fixtures/project/sample_material.tres --json --no-validate) &&
        \\echo "$out" | grep -q '"kind":"color"' &&
        \\echo "$out" | grep -q 'albedo_color'
    });
    material_inspect_smoke.setCwd(b.path("."));
    material_inspect_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&material_inspect_smoke.step);

    // `catalog add` scaffolds a JSON manifest, filling scene_uid from the scene
    // header and one signal row per signal the root script declares.
    const catalog_add_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d /tmp/godot_cli_catalog.XXXXXX) &&
        \\cp -R test_fixtures/project/. "$tmp/" &&
        \\rm -f "$tmp/ui/button.manifest.json" "$tmp/instanced_child.manifest.json" &&
        \\out=$(./zig-out/bin/godot-cli catalog add res://ui/button/button.tscn \
        \\  --project-root "$tmp" --summary "A button" --when-to-use "UI" --tags ui,button --json) &&
        \\echo "$out" | grep -q '"signals_scaffolded":1' &&
        \\grep -q '"catalog_format_version": 2' "$tmp/ui/button/button.manifest.json" &&
        \\grep -q '"id": "ui/button/button"' "$tmp/ui/button/button.manifest.json" &&
        \\grep -q '"name": "button_pressed"' "$tmp/ui/button/button.manifest.json" &&
        \\grep -q 'uid://byhqeak2spha2' "$tmp/ui/button/button.manifest.json" &&
        \\scan=$(./zig-out/bin/godot-cli catalog scan --project-root "$tmp" --json) &&
        \\echo "$scan" | grep -q '"id":"ui/button/button"' &&
        \\echo "$scan" | grep -q '"catalog_format_version":2' &&
        \\rm -rf "$tmp"
    });
    catalog_add_smoke.setCwd(b.path("."));
    catalog_add_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_add_smoke.step);

    // --update keeps prose a human wrote and refuses to clobber without it.
    const catalog_update_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d /tmp/godot_cli_catalog_up.XXXXXX) &&
        \\cp -R test_fixtures/project/. "$tmp/" &&
        \\rm -f "$tmp/ui/button.manifest.json" &&
        \\./zig-out/bin/godot-cli catalog add res://instanced_child.tscn \
        \\  --project-root "$tmp" --update --summary "Edited summary" --json >/dev/null &&
        \\grep -q '"summary": "Edited summary"' "$tmp/instanced_child.manifest.json" &&
        \\grep -q 'child_ready' "$tmp/instanced_child.manifest.json" &&
        \\grep -q 'intro animation' "$tmp/instanced_child.manifest.json" &&
        \\if ./zig-out/bin/godot-cli catalog add res://instanced_child.tscn \
        \\     --project-root "$tmp" --json >/dev/null 2>&1; then exit 1; fi &&
        \\rm -rf "$tmp"
    });
    catalog_update_smoke.setCwd(b.path("."));
    catalog_update_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_update_smoke.step);

    // `catalog relink` refuses to guess when the uid cache has not caught up
    // with the move. The repair itself is unit-tested in catalog_relink.zig,
    // which builds its own uid cache rather than needing Godot to regenerate one.
    const catalog_relink_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d /tmp/godot_cli_relink.XXXXXX) &&
        \\cp -R test_fixtures/project/. "$tmp/" &&
        \\rm -f "$tmp/ui/button.manifest.json" "$tmp/instanced_child.manifest.json" &&
        \\./zig-out/bin/godot-cli catalog add res://ui/button/button.tscn \
        \\  --project-root "$tmp" --id ui/button --summary "Standard button" \
        \\  --when-to-use "UI" --tags ui,button --json >/dev/null &&
        \\mkdir -p "$tmp/widgets" && mv "$tmp/ui/button" "$tmp/widgets/button" &&
        \\if ./zig-out/bin/godot-cli catalog validate --project-root "$tmp" >/dev/null 2>&1; then exit 1; fi &&
        \\out=$(./zig-out/bin/godot-cli catalog relink --project-root "$tmp" --json 2>/dev/null || true) &&
        \\echo "$out" | grep -q '"relinked":1' &&
        \\grep -q 'res://widgets/button/button.tscn' "$tmp/widgets/button/button.manifest.json" &&
        \\./zig-out/bin/godot-cli catalog validate --project-root "$tmp" >/dev/null 2>&1 &&
        \\rm -rf "$tmp"
    });
    catalog_relink_smoke.setCwd(b.path("."));
    catalog_relink_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&catalog_relink_smoke.step);

    // Regression: stdout must respect the shell-owned file offset. With a
    // positional-mode writer every invocation pwrites at offset 0 and clobbers
    // whatever the redirect target already holds.
    const stdout_redirect_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp /tmp/godot_cli_redirect.XXXXXX) &&
        \\echo "leading line that must survive" >"$tmp" &&
        \\./zig-out/bin/godot-cli ping >>"$tmp" &&
        \\./zig-out/bin/godot-cli uid encode 1350303725746704497 >>"$tmp" &&
        \\out=$(cat "$tmp") &&
        \\rm -f "$tmp" &&
        \\[ "$(echo "$out" | sed -n 1p)" = "leading line that must survive" ] &&
        \\[ "$(echo "$out" | sed -n 2p)" = "pong" ] &&
        \\echo "$out" | grep -q 'uid://tidkmw585t0t'
    });
    stdout_redirect_smoke.setCwd(b.path("."));
    stdout_redirect_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&stdout_redirect_smoke.step);

    const godot_bin = b.option([]const u8, "godot", "Path to Godot binary for reference generation") orelse "/Applications/Godot.app/Contents/MacOS/Godot";
    const godot_step = b.step("test-godot", "Import fixtures, generate Godot reference save, run round-trip CLI check");
    const import_cmd = b.addSystemCommand(&.{ "bash", "tools/import_fixtures.sh" });
    import_cmd.setCwd(b.path("."));
    import_cmd.setEnvironmentVariable("GODOT", godot_bin);
    godot_step.dependOn(&import_cmd.step);
    const godot_cmd = b.addSystemCommand(&.{ godot_bin, "--headless", "--path", "test_fixtures/project", "--script", "save_reference.gd" });
    godot_cmd.setCwd(b.path("."));
    godot_cmd.step.dependOn(&import_cmd.step);
    godot_step.dependOn(&godot_cmd.step);
    const sync_session_cmd = b.addSystemCommand(&.{ "bash", "tools/sync_id_session.sh" });
    sync_session_cmd.setCwd(b.path("."));
    sync_session_cmd.step.dependOn(&godot_cmd.step);
    sync_session_cmd.step.dependOn(b.getInstallStep());
    godot_step.dependOn(&sync_session_cmd.step);
    const roundtrip_cmd = b.addRunArtifact(exe);
    roundtrip_cmd.addArgs(&.{ "scene", "round-trip", "test_fixtures/project/sample.tscn", "--dry-run" });
    roundtrip_cmd.step.dependOn(&godot_cmd.step);
    roundtrip_cmd.step.dependOn(b.getInstallStep());
    godot_step.dependOn(&roundtrip_cmd.step);
    // project run against the fixture, headless so it works on a runner with
    // no display; the fixture's SceneTree script logs an error on load, which
    // is exactly what the error extraction is for.
    const run_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\out=$(./zig-out/bin/godot-cli project run --project-root test_fixtures/project --godot "$GODOT" --scene sample.tscn --frames 3 --headless --json || true) &&
        \\echo "$out" | grep -q '"import_exit":0' && echo "$out" | grep -q '"error_count":' && echo "$out" | grep -q '"log_tail":' &&
        \\out=$(./zig-out/bin/godot-cli project run --project-root test_fixtures/project --godot "$GODOT" --scene sample.tscn --frames 4 --headless --no-import --press ui_accept@1..2 --json || true) &&
        \\echo "$out" | grep -q '"presses":1' && test -f test_fixtures/project/.godot/godot-cli/godot_cli_run.gd &&
        \\grep -q 'InputEventAction' test_fixtures/project/.godot/godot-cli/godot_cli_run.gd &&
        \\out=$(./zig-out/bin/godot-cli project run --project-root test_fixtures/project --godot "$GODOT" --scene sample.tscn --frames 4 --headless --no-import --click /root/Root@2 --json || true) &&
        \\echo "$out" | grep -q '"clicks":1' &&
        \\test -f test_fixtures/project/.godot/godot-cli/godot.log &&
        \\./zig-out/bin/godot-cli project import --project-root test_fixtures/project --godot "$GODOT" --json | grep -q '"ok":true' &&
        \\rm -rf test_fixtures/project/.godot/godot-cli
    });
    run_smoke.setCwd(b.path("."));
    run_smoke.setEnvironmentVariable("GODOT", godot_bin);
    run_smoke.step.dependOn(&godot_cmd.step);
    run_smoke.step.dependOn(b.getInstallStep());
    godot_step.dependOn(&run_smoke.step);
    const compare_cmd = b.addRunArtifact(exe);
    compare_cmd.addArgs(&.{
        "scene",                                         "compare-godot", "test_fixtures/project/sample.tscn",
        "test_fixtures/project/sample_godot_saved.tscn", "--json",
    });
    compare_cmd.step.dependOn(&godot_cmd.step);
    compare_cmd.step.dependOn(b.getInstallStep());
    godot_step.dependOn(&compare_cmd.step);
    const normalize_cmd = b.addRunArtifact(exe);
    normalize_cmd.addArgs(&.{
        "scene",                             "normalize",
        "test_fixtures/project/sample.tscn", "--output",
        "zig-out/sample_normalized.tscn",    "--project-root",
        "test_fixtures/project",             "--resource-path",
        "res://sample.tscn",                 "--godot-save-format",
    });
    normalize_cmd.step.dependOn(&godot_cmd.step);
    normalize_cmd.step.dependOn(b.getInstallStep());
    // Byte-identical output depends on the ext_resource ids Godot just wrote, so
    // the session cache has to be synced from that save before normalizing.
    // Without this edge the two steps race, and on a clean checkout — with no
    // stale cache to fall back on — the cmp below fails.
    normalize_cmd.step.dependOn(&sync_session_cmd.step);
    godot_step.dependOn(&normalize_cmd.step);
    const cmp_cmd = b.addSystemCommand(&.{ "cmp", "zig-out/sample_normalized.tscn", "test_fixtures/project/sample_godot_saved.tscn" });
    cmp_cmd.step.dependOn(&normalize_cmd.step);
    godot_step.dependOn(&cmp_cmd.step);

    // Property values written through the Variant parser, checked in the file
    // rather than in the command's own JSON: `sub add --property` used to free
    // the normalized value before the document copied it, so the scene got
    // whatever the allocator left behind.
    const property_value_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\scene="$tmp/props.tscn" &&
        \\./zig-out/bin/godot-cli scene new --output "$scene" --root-name Root --root-type Node2D &&
        \\./zig-out/bin/godot-cli scene sub add "$scene" --type CapsuleShape2D --property radius --value 16.0 &&
        \\./zig-out/bin/godot-cli scene sub add "$scene" --type RectangleShape2D --property size --value "Vector2(16, 32)" &&
        \\./zig-out/bin/godot-cli scene set-property "$scene" --node-name Root --property rotation --value 1.5 &&
        \\grep -q '^radius = 16.0$' "$scene" &&
        \\grep -q '^size = Vector2(16, 32)$' "$scene" &&
        \\grep -q '^rotation = 1.5$' "$scene"
    });
    property_value_smoke.setCwd(b.path("."));
    property_value_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&property_value_smoke.step);

    // A project that has never been opened in Godot has no .godot directory, so
    // the id session cache has nowhere to be written. That used to fail the
    // command *after* the scene was already written.
    const fresh_project_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\touch "$tmp/project.godot" &&
        \\mkdir -p "$tmp/ui" &&
        \\printf '[gd_scene format=3]\n\n[node name="HUD" type="Control"]\n' > "$tmp/ui/hud.tscn" &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp/level.tscn" --root-name Level --root-type Node2D &&
        \\./zig-out/bin/godot-cli scene instance add "$tmp/level.tscn" --parent /root/Level \
        \\  --scene res://ui/hud.tscn --name HUD --project-root "$tmp" --json &&
        \\grep -q 'instance=ExtResource' "$tmp/level.tscn"
    });
    fresh_project_smoke.setCwd(b.path("."));
    fresh_project_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&fresh_project_smoke.step);

    // Findings from driving the tool with a fresh agent: a bare word as a
    // property value used to be written verbatim (invalid scene), inspect
    // emitted bare `inf` (invalid JSON), and id_hint ids tripped the validator.
    const agent_findings_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\touch "$tmp/project.godot" && printf 'extends Control\n' > "$tmp/pm.gd" &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp/a.tscn" --root-name Main --root-type Control --project-root "$tmp" &&
        \\printf '{ "steps": [ { "recipe": "add_node", "parent": "/root/Main", "name": "Title", "type": "Label", "properties": { "text": "Paused" } } ] }' > "$tmp/bad.json" &&
        \\out=$(./zig-out/bin/godot-cli scene apply "$tmp/a.tscn" --intent "$tmp/bad.json" --project-root "$tmp" --json || true) &&
        \\echo "$out" | grep -q '"kind":"invalid_property_value"' &&
        \\echo "$out" | grep -q '"field":"text"' &&
        \\! grep -q '^text' "$tmp/a.tscn" &&
        \\printf '{ "steps": [ { "recipe": "assign_ext", "path": "/root/Main", "property": "script", "type": "Script", "res_path": "res://pm.gd", "id_hint": "pause_menu" } ] }' > "$tmp/ext.json" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp/a.tscn" --intent "$tmp/ext.json" --project-root "$tmp" --json | grep -q '"ok":true' &&
        \\./zig-out/bin/godot-cli scene validate "$tmp/a.tscn" --project-root "$tmp" --json | grep -q '"issues":\[\]' &&
        \\./zig-out/bin/godot-cli scene set-property "$tmp/a.tscn" --node /root/Main --property probe --value inf --raw-value --project-root "$tmp" &&
        \\./zig-out/bin/godot-cli scene inspect "$tmp/a.tscn" --json | python3 -c 'import json,sys; json.load(sys.stdin)'
    });
    agent_findings_smoke.setCwd(b.path("."));
    agent_findings_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&agent_findings_smoke.step);

    // Signal connections against a scene Godot itself saved: the file has to
    // survive a rewrite byte for byte (binds= [...] spacing, no blank lines
    // between connections), renames have to follow, and a dangling endpoint
    // has to fail validation.
    const connections_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\ref=test_fixtures/project/ui/menu/menu_godot_saved.tscn &&
        \\./zig-out/bin/godot-cli scene normalize "$ref" --output "$tmp/rt.tscn" --project-root test_fixtures/project --resource-path res://ui/menu/menu.tscn &&
        \\cmp "$ref" "$tmp/rt.tscn" &&
        \\cp "$ref" "$tmp/m.tscn" &&
        \\./zig-out/bin/godot-cli scene connection add "$tmp/m.tscn" --from /root/Menu/Bar --signal drag_ended --to /root/Menu --method _on_drag --one-shot --no-prepare-save --json | grep -q '"ok":true' &&
        \\grep -q '^\[connection signal="drag_ended" from="Bar" to="." method="_on_drag" flags=6\]$' "$tmp/m.tscn" &&
        \\./zig-out/bin/godot-cli scene node rename "$tmp/m.tscn" /root/Menu/Box --name Panel --no-prepare-save &&
        \\grep -q 'from="Panel/Quit" to="." method="_on_quit_pressed" flags=3 binds= \["quit"\]' "$tmp/m.tscn" &&
        \\./zig-out/bin/godot-cli scene node remove "$tmp/m.tscn" /root/Menu/Panel/Quit --no-prepare-save &&
        \\! grep -q '_on_quit_pressed' "$tmp/m.tscn" &&
        \\./zig-out/bin/godot-cli scene connection list "$tmp/m.tscn" --json | grep -q '"connection_count":3' &&
        \\printf '[gd_scene format=3]\n\n[node name="Menu" type="Control"]\n\n[connection signal="pressed" from="Gone" to="." method="_on_gone"]\n' > "$tmp/bad.tscn" &&
        \\! ./zig-out/bin/godot-cli scene validate "$tmp/bad.tscn" --json >/dev/null &&
        \\./zig-out/bin/godot-cli scene validate "$tmp/bad.tscn" --json | grep -q connection_node_missing
    });
    connections_smoke.setCwd(b.path("."));
    connections_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&connections_smoke.step);

    // A script's UID lives in its .uid sidecar once Godot has imported it, and
    // stays put when the script is edited. validate must trust the sidecar, and
    // a save with a project root must repair a uid= that disagrees with it (a
    // component copied in from another project). Also: repeated --property.
    const uid_sidecar_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\printf 'config_version=5\n\n[application]\n\nconfig/name="Uid"\n' > "$tmp/project.godot" &&
        \\printf 'extends Node\n' > "$tmp/thing.gd" &&
        \\printf 'uid://bqpgupk3krulf\n' > "$tmp/thing.gd.uid" &&
        \\printf '[gd_scene format=3 load_steps=2]\n\n[ext_resource type="Script" path="res://thing.gd" id="1_a1b2c" uid="uid://d0ldlsj0t7bwh"]\n\n[node name="Main" type="Node" unique_id=1]\nscript = ExtResource("1_a1b2c")\n' > "$tmp/a.tscn" &&
        \\./zig-out/bin/godot-cli scene validate "$tmp/a.tscn" --project-root "$tmp" --json | grep -q stale_uid_for_path &&
        \\./zig-out/bin/godot-cli scene normalize "$tmp/a.tscn" --output "$tmp/a.tscn" --project-root "$tmp" --resource-path res://a.tscn >/dev/null &&
        \\grep -q 'uid="uid://bqpgupk3krulf"' "$tmp/a.tscn" &&
        \\! ./zig-out/bin/godot-cli scene validate "$tmp/a.tscn" --project-root "$tmp" --json | grep -q stale_uid_for_path &&
        \\printf 'extends Node\nfunc _ready() -> void:\n\tpass\n' > "$tmp/thing.gd" &&
        \\! ./zig-out/bin/godot-cli scene validate "$tmp/a.tscn" --project-root "$tmp" --json | grep -q stale_uid_for_path &&
        \\./zig-out/bin/godot-cli scene node add "$tmp/a.tscn" --parent /root/Main --name HUD --type Control --property anchor_right --value 1.0 --property anchor_bottom --value 1.0 --project-root "$tmp" --json | grep -q '"ok":true' &&
        \\grep -q '^anchor_right = 1.0$' "$tmp/a.tscn" && grep -q '^anchor_bottom = 1.0$' "$tmp/a.tscn"
    });
    uid_sidecar_smoke.setCwd(b.path("."));
    uid_sidecar_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&uid_sidecar_smoke.step);

    // Resource authoring against files Godot itself saved, the sub-resource
    // placement fix (they used to land after [resource]), set-property's
    // default section, the static_body_2d recipe, and scene new creating a
    // missing parent directory.
    const resource_authoring_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\touch "$tmp/project.godot" &&
        \\./zig-out/bin/godot-cli resource new --output "$tmp/mat/wood.tres" --type StandardMaterial3D --property albedo_color --value "Color(1, 0.5, 0.25, 1)" --property roughness --value 0.8 --no-uid --project-root "$tmp" >/dev/null &&
        \\cmp "$tmp/mat/wood.tres" test_fixtures/project/resources/mat_godot_saved.tres &&
        \\./zig-out/bin/godot-cli resource new --output "$tmp/shape.tres" --type RectangleShape2D --property size --value "Vector2(64, 16)" --no-uid --project-root "$tmp" >/dev/null &&
        \\cmp "$tmp/shape.tres" test_fixtures/project/resources/shape_godot_saved.tres &&
        \\./zig-out/bin/godot-cli resource new --output "$tmp/theme.tres" --type Theme --no-uid --project-root "$tmp" >/dev/null &&
        \\./zig-out/bin/godot-cli resource sub add "$tmp/theme.tres" --type StyleBoxFlat --property bg_color --value "Color(0.1, 0.1, 0.1, 1)" --property corner_radius_top_left --value 6 --project-root "$tmp" >/dev/null &&
        \\id=$(grep -o 'id="StyleBoxFlat_[^"]*"' "$tmp/theme.tres" | cut -d'"' -f2) &&
        \\./zig-out/bin/godot-cli resource set-property "$tmp/theme.tres" --property Button/styles/normal --value "SubResource(\"$id\")" --project-root "$tmp" >/dev/null &&
        \\./zig-out/bin/godot-cli resource set-property "$tmp/theme.tres" --property Label/colors/font_color --value "Color(1, 1, 1, 1)" --project-root "$tmp" >/dev/null &&
        \\./zig-out/bin/godot-cli resource set-property "$tmp/theme.tres" --property Label/font_sizes/font_size --value 20 --project-root "$tmp" >/dev/null &&
        \\grep -n '^\[' "$tmp/theme.tres" | tr '\n' ' ' | grep -q 'gd_resource.*sub_resource.*resource' &&
        \\./zig-out/bin/godot-cli resource compare-godot "$tmp/theme.tres" test_fixtures/project/resources/theme_godot_saved.tres --json | grep -q '"matches_godot_save":true' &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp/scenes/m.tscn" --root-name Main --root-type Node2D --project-root "$tmp" >/dev/null &&
        \\printf '{ "steps": [ { "recipe": "static_body_2d", "parent": "/root/Main", "name": "Ground", "size": "Vector2(640, 16)" } ] }' > "$tmp/g.json" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp/scenes/m.tscn" --intent "$tmp/g.json" --project-root "$tmp" --json | grep -q '"applied_count":3' &&
        \\grep -q 'type="StaticBody2D"' "$tmp/scenes/m.tscn" && grep -q '^size = Vector2(640, 16)$' "$tmp/scenes/m.tscn"
    });
    resource_authoring_smoke.setCwd(b.path("."));
    resource_authoring_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&resource_authoring_smoke.step);

    // project.godot as Godot writes it (blank line before and after each
    // section header) has to survive a settings edit byte for byte.
    const project_godot_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\cp test_fixtures/project/project_godot_saved.godot "$tmp/project.godot" &&
        \\./zig-out/bin/godot-cli project settings set --project-root "$tmp" --section application --key config/name --value PgRef >/dev/null &&
        \\cmp "$tmp/project.godot" test_fixtures/project/project_godot_saved.godot
    });
    project_godot_smoke.setCwd(b.path("."));
    project_godot_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_godot_smoke.step);

    // The catalog after a folder move, as the relink trial did it: a scene
    // godot-cli created (so no scene_uid), its manifest, and its script move
    // together; relink must find the scene beside the manifest, repoint the
    // manifest, and rewrite the script path inside the scene. Also: export
    // keeps the rules above the digest, and catalog add takes a relative path.
    const relink_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\printf 'config_version=5\n\n[application]\n\nconfig/name="Relink"\n' > "$tmp/project.godot" &&
        \\mkdir -p "$tmp/ui/button" && printf 'extends Button\nsignal tapped\n' > "$tmp/ui/button/button.gd" &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp/ui/button/button.tscn" --root-name B --root-type Button --project-root "$tmp" >/dev/null &&
        \\printf '{ "ops": [ { "op": "assign_ext", "path": "/root/B", "property": "script", "type": "Script", "res_path": "res://ui/button/button.gd" } ] }' > "$tmp/p.json" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp/ui/button/button.tscn" --patch "$tmp/p.json" --project-root "$tmp" >/dev/null &&
        \\./zig-out/bin/godot-cli catalog add ui/button/button.tscn --id ui/button --summary "A button" --project-root "$tmp" --json | grep -q '"ok":true' &&
        \\printf '# Rules\n\nKeep me.\n' > "$tmp/AGENTS.md" &&
        \\./zig-out/bin/godot-cli catalog export --project-root "$tmp" --output AGENTS.md >/dev/null &&
        \\./zig-out/bin/godot-cli catalog export --project-root "$tmp" --output AGENTS.md >/dev/null &&
        \\grep -q 'Keep me' "$tmp/AGENTS.md" && [ "$(grep -c '^# Component Catalog' "$tmp/AGENTS.md")" = 1 ] &&
        \\mkdir -p "$tmp/components" && mv "$tmp/ui/button" "$tmp/components/button" && rmdir "$tmp/ui" &&
        \\./zig-out/bin/godot-cli catalog relink --project-root "$tmp" --json | grep -q '"status":"relinked"' &&
        \\grep -q 'res://components/button/button.tscn' "$tmp/components/button/button.manifest.json" &&
        \\grep -q 'path="res://components/button/button.gd"' "$tmp/components/button/button.tscn" &&
        \\./zig-out/bin/godot-cli catalog validate --project-root "$tmp" --json | grep -q '"valid":true'
    });
    relink_smoke.setCwd(b.path("."));
    relink_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&relink_smoke.step);

    // project move: the file, its .uid sidecar, every ext_resource path, and
    // the main-scene setting all move together.
    const project_move_smoke = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d) &&
        \\trap 'rm -rf "$tmp"' EXIT &&
        \\printf 'config_version=5\n\n[application]\n\nconfig/name="Move"\nrun/main_scene="res://scenes/a.tscn"\n' > "$tmp/project.godot" &&
        \\mkdir -p "$tmp/scripts" && printf 'extends Node\n' > "$tmp/scripts/p.gd" && printf 'uid://abc\n' > "$tmp/scripts/p.gd.uid" &&
        \\./zig-out/bin/godot-cli scene new --output "$tmp/scenes/a.tscn" --root-name A --root-type Node --project-root "$tmp" >/dev/null &&
        \\printf '{ "ops": [ { "op": "assign_ext", "path": "/root/A", "property": "script", "type": "Script", "res_path": "res://scripts/p.gd" } ] }' > "$tmp/p.json" &&
        \\./zig-out/bin/godot-cli scene apply "$tmp/scenes/a.tscn" --patch "$tmp/p.json" --project-root "$tmp" >/dev/null &&
        \\./zig-out/bin/godot-cli project move --project-root "$tmp" --from scripts/p.gd --to scripts/hero/h.gd --json | grep -q '"references_retargeted":1' &&
        \\test -f "$tmp/scripts/hero/h.gd" && test -f "$tmp/scripts/hero/h.gd.uid" && ! test -e "$tmp/scripts/p.gd" &&
        \\grep -q 'path="res://scripts/hero/h.gd"' "$tmp/scenes/a.tscn" &&
        \\./zig-out/bin/godot-cli project move --project-root "$tmp" --from res://scenes/a.tscn --to res://levels/one.tscn --json | grep -q '"settings_updated":1' &&
        \\grep -q 'run/main_scene="res://levels/one.tscn"' "$tmp/project.godot" &&
        \\./zig-out/bin/godot-cli scene validate "$tmp/levels/one.tscn" --project-root "$tmp" --json | grep -q '"error_count":0'
    });
    project_move_smoke.setCwd(b.path("."));
    project_move_smoke.step.dependOn(b.getInstallStep());
    test_step.dependOn(&project_move_smoke.step);

    // Generated CLI surface: the Markdown command reference, the man page, and
    // the shell completions all come from the CommandSpec tree, so they are
    // rebuilt by `zig build docs` and diffed by `zig build docs-check`.
    const docs_step = b.step("docs", "Regenerate command reference, man page, and shell completions");
    const docs_cmd = b.addSystemCommand(&.{
        "bash", "-ec",
        \\mkdir -p docs share/man/man1 share/completions &&
        \\./zig-out/bin/godot-cli reference --output docs/commands.md &&
        \\./zig-out/bin/godot-cli man --output share/man/man1/godot-cli.1 &&
        \\./zig-out/bin/godot-cli completions bash --output share/completions/godot-cli.bash &&
        \\./zig-out/bin/godot-cli completions zsh --output share/completions/_godot-cli &&
        \\./zig-out/bin/godot-cli completions fish --output share/completions/godot-cli.fish
    });
    docs_cmd.setCwd(b.path("."));
    docs_cmd.step.dependOn(b.getInstallStep());
    docs_step.dependOn(&docs_cmd.step);

    const docs_check_step = b.step("docs-check", "Fail if generated docs, man page, or completions are stale");
    const docs_check_cmd = b.addSystemCommand(&.{
        "bash", "-ec",
        \\tmp=$(mktemp -d)
        \\trap 'rm -rf "$tmp"' EXIT
        \\./zig-out/bin/godot-cli reference --output "$tmp/commands.md" >/dev/null
        \\./zig-out/bin/godot-cli man --output "$tmp/godot-cli.1" >/dev/null
        \\./zig-out/bin/godot-cli completions bash --output "$tmp/godot-cli.bash" >/dev/null
        \\./zig-out/bin/godot-cli completions zsh --output "$tmp/_godot-cli" >/dev/null
        \\./zig-out/bin/godot-cli completions fish --output "$tmp/godot-cli.fish" >/dev/null
        \\status=0
        \\for pair in \
        \\  "docs/commands.md $tmp/commands.md" \
        \\  "share/man/man1/godot-cli.1 $tmp/godot-cli.1" \
        \\  "share/completions/godot-cli.bash $tmp/godot-cli.bash" \
        \\  "share/completions/_godot-cli $tmp/_godot-cli" \
        \\  "share/completions/godot-cli.fish $tmp/godot-cli.fish"
        \\do
        \\  set -- $pair
        \\  if ! diff -u "$1" "$2"; then status=1; fi
        \\done
        \\if [ "$status" -ne 0 ]; then
        \\  echo "generated CLI docs are stale — run: zig build docs" >&2
        \\  exit 1
        \\fi
    });
    docs_check_cmd.setCwd(b.path("."));
    docs_check_cmd.step.dependOn(b.getInstallStep());
    docs_check_step.dependOn(&docs_check_cmd.step);

    // Just like flags, top level steps are also listed in the `--help` menu.
    //
    // The Zig build system is entirely implemented in userland, which means
    // that it cannot hook into private compiler APIs. All compilation work
    // orchestrated by the build system will result in other Zig compiler
    // subcommands being invoked with the right flags defined. You can observe
    // these invocations when one fails (or you pass a flag to increase
    // verbosity) to validate assumptions and diagnose problems.
    //
    // Lastly, the Zig build system is relatively simple and self-contained,
    // and reading its source code will allow you to master it.
}
