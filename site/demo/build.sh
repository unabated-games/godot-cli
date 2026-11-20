#!/usr/bin/env bash
# Builds Gem Grove from nothing: art, a font and five scripts go in, and every
# scene, resource id, connection and project setting is written by godot-cli.
# A frame is captured after each stage into frames/.
set -euo pipefail
cd "$(dirname "$0")"
G="${GODOT_CLI:-godot-cli}"
P=gem-grove
rm -rf "$P" frames && mkdir -p "$P" frames
cp -R src/art src/fonts src/scripts src/audio "$P"/

run() { "$G" "$@" --project-root "$P" --json > .last.json || { cat .last.json; exit 1; }; }
shot() { # shot <name> [project run options]
  local name=$1; shift
  run project run "$@"
  cp "$(python3 -c 'import json;print(json.load(open(".last.json"))["data"]["frame"])')" "frames/$name.png"
}

# Stage 1: a project, an input map, and a level with a background
run project new --name "Gem Grove" --main-scene res://main.tscn --width 960 --height 540
run project input apply --intent intents/input.json
# Scale the 960x540 view to whatever window or browser canvas it gets
run project settings set --section display --key window/stretch/mode --value '"canvas_items"'
run project settings set --section display --key window/stretch/aspect --value '"keep"'
run project settings set --section rendering --key environment/defaults/default_clear_color --value 'Color(0.2, 0.45, 0.3, 1)'
run scene new --output "$P/main.tscn" --root-name Main --root-type Node2D
run scene apply "$P/main.tscn" --patch intents/level_background.json
shot 1-level --frames 5

# Stage 2: three actors, each its own scene with a catalog entry, placed in the level
for actor in player:CharacterBody2D gem:Area2D slime:Area2D; do
  name=${actor%%:*}; type=${actor##*:}
  Name="$(tr '[:lower:]' '[:upper:]' <<< "${name:0:1}")${name:1}"
  run scene new --output "$P/actors/$name.tscn" --root-name "$Name" --root-type "$type" --script "res://scripts/$name.gd"
  run scene apply "$P/actors/$name.tscn" --patch "intents/$name.json"
done
run catalog add "$P/actors/player.tscn" --id actors/player --summary "The robot the player steers" \
  --when-to-use "Once per level"
run catalog add "$P/actors/gem.tscn" --id actors/gem --summary "A gem that emits collected when the player touches it" \
  --when-to-use "Anything the player picks up for score"
run catalog add "$P/actors/slime.tscn" --id actors/slime --summary "A slime that bounces around the level and emits touched" \
  --when-to-use "A moving hazard; set velocity on the instance"
# The burst a gem leaves behind. The game spawns it while playing, so it is a
# scene of its own and is not placed in the level
run scene new --output "$P/actors/pickup_fx.tscn" --root-name PickupFx --root-type Node2D --script res://scripts/pickup_fx.gd
run scene apply "$P/actors/pickup_fx.tscn" --patch intents/pickup_fx.json
run scene apply "$P/main.tscn" --patch intents/level_actors.json
shot 2-actors --frames 5

# Stage 3: the HUD, built from two small widgets
run scene new --output "$P/ui/big_button.tscn" --root-name BigButton --root-type Button
run scene apply "$P/ui/big_button.tscn" --patch intents/big_button.json
run catalog add "$P/ui/big_button.tscn" --id ui/big_button --summary "The chunky coral button" \
  --when-to-use "Any primary action; override text on the instance" --when-not-to-use "Small inline controls"
run scene new --output "$P/ui/heart.tscn" --root-name Heart --root-type TextureRect
run scene apply "$P/ui/heart.tscn" --patch intents/heart.json
run catalog add "$P/ui/heart.tscn" --id ui/heart --summary "One heart of the health row"
run scene new --output "$P/ui/hud.tscn" --root-name HUD --root-type CanvasLayer --script res://scripts/hud.gd
run scene apply "$P/ui/hud.tscn" --patch intents/hud.json
run catalog add "$P/ui/hud.tscn" --id ui/hud --summary "Hearts, score, title card and game over card"
run scene apply "$P/main.tscn" --patch intents/level_hud.json
shot 3-hud --frames 5

# Stage 4: the rules. One script on the root, eleven signal connections, and
# three sound players
run scene apply "$P/main.tscn" --patch intents/level_rules.json
for scene in main actors/player actors/gem actors/slime actors/pickup_fx ui/big_button ui/heart ui/hud; do
  run scene validate "$P/$scene.tscn"
done
shot 4-play --frames 178 --click /root/Main/HUD/Center/TitleCard/Column/PlayButton@10 \
  --press move_right@20..55 --press move_up@50..75 --press move_left@80..170 --user-arg --seed=7

# Optional: WEB=1 exports the game for the browser into web/. It needs Godot's
# export templates, for the Godot in $GODOT_EXPORT if that is set, else for the
# one the rest of the build used.
if [ "${WEB:-0}" = 1 ]; then
  run project export apply --intent intents/export_web.json
  mkdir -p "$P/build/web"
  run project export build --preset Web ${GODOT_EXPORT:+--godot "$GODOT_EXPORT"}
  rm -rf web && cp -R "$P/build/web" web
  echo "exported web/"
fi
rm -f .last.json
echo "built $P, frames in frames/"
