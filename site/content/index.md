---
title: godot-cli
description: Faster, safer Godot scene edits for coding agents. One command for a whole scene change, checked against Godot's own class reference, in files that match the editor's saves byte for byte.
layout: landing
format: html
---

<section class="hero">
  <div class="wrap hero-inner">
    <div class="hero-copy">
      <div class="hero-chips">
        <span class="chip mint">For Godot 4</span>
        <span class="chip">MIT licensed</span>
      </div>
      <h1><em>Faster, safer</em> Godot scene edits for agents</h1>
      <p class="lede">godot-cli gives a coding agent one command for a whole scene change, from a terminal or over MCP. Every edit is checked against Godot's own class reference, and the <code>.tscn</code>, <code>.tres</code> and <code>project.godot</code> files it writes match the editor's saves byte for byte.</p>
      <div class="install">
        <div class="install-box">
          <pre id="install-hero"><span class="p">$</span> curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash</pre>
          <button class="copy" type="button" data-copy="install-hero" aria-label="Copy the install command"><svg aria-hidden="true" viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg></button>
        </div>
        <span class="install-note">Linux, macOS and Windows, x86_64 and aarch64. One binary with no runtime dependencies.</span>
      </div>
      <div class="hero-actions">
        <a class="btn" href="{{ base_url }}/getting-started/">Install the CLI</a>
        <a class="hero-secondary" href="#demo"><svg aria-hidden="true" viewBox="0 0 24 24" width="22" height="22"><path d="M7 4.5v15l12-7.5z" fill="#6ee7d8" stroke="#6ee7d8" stroke-width="2" stroke-linejoin="round"/></svg><!-- demo:play -->Play the game it built<!-- /demo:play --><!-- demo:still -->See the game it built<!-- /demo:still --></a>
      </div>
    </div>

    <figure class="hero-art">
      <div class="game-window">
        <div class="window-bar"><i></i><i></i><i></i>Gem Grove</div>
        <img src="{{ base_url }}/assets/demo/4-play.webp?v={{ asset_hash }}" width="960" height="540" alt="Gem Grove running: a robot in a forest clearing with gems and three purple slimes, three hearts top left and a score of 2 top right">
      </div>
      <pre class="term hero-term"><span class="p">$</span> godot-cli scene instance add main.tscn \
    --parent /root/Main --name HUD <span class="hl">--catalog-id ui/hud</span>
<span class="dim">[node name="HUD" parent="." unique_id=1886270267
  instance=ExtResource("4_7dm0k")]</span></pre>
      <figcaption>A frame from Gem Grove, the demo further down. Every scene in it was written by godot-cli.</figcaption>
    </figure>
  </div>
</section>

<div class="proof">
  <ul class="wrap">
    <li>v{{ version }}, released {{ released }}</li>
    <li>Compared with Godot's own saves on every push</li>
    <li>Type-checked against Godot's class reference</li>
    <li>Works in Claude Code, Cursor and OpenCode</li>
  </ul>
</div>

<section class="wrap section">
  <div class="section-head">
    <h2>Ask an agent for a HUD and look at the scene tree</h2>
    <p>Scene text is hard to write blind, so an agent left alone builds the HUD in GDScript. The game runs and the scene stays empty. godot-cli gives it a safe way to put the nodes where the editor expects them.</p>
  </div>
  <div class="versus">
    <div class="panel">
      <span class="chip grey">Without godot-cli</span>
      <pre class="term"><span class="kw">func</span> _ready() -> <span class="p">void</span>:
    <span class="kw">var</span> bar = load(<span class="hl">"res://ui/health_bar/health_bar.tscn"</span>).instantiate()
    add_child(bar)</pre>
      <div class="dock">
        <div class="dock-title">Scene dock: hud.tscn</div>
        <ul>
          <li>HUD</li>
          <li class="empty">Nothing else here. The layout exists only while the game is playing.</li>
        </ul>
      </div>
    </div>
    <div class="panel good">
      <span class="chip mint">With godot-cli</span>
      <pre class="term"><span class="p">$</span> godot-cli scene instance add hud.tscn \
    --parent /root/HUD --name PlayerHealth \
    <span class="hl">--catalog-id ui/health_bar</span> --project-root .</pre>
      <div class="dock">
        <div class="dock-title">Scene dock: hud.tscn</div>
        <ul>
          <li>HUD</li>
          <li class="d1 new">PlayerHealth <small>instance of ui/health_bar</small></li>
          <li class="d1">Score</li>
          <li class="d1">PauseButton</li>
        </ul>
      </div>
    </div>
  </div>
</section>

<section class="wrap section" id="demo">
  <img class="keyart" src="{{ base_url }}/assets/demo/keyart.webp?v={{ asset_hash }}" width="1600" height="893" alt="Key art for Gem Grove: the robot runs through a forest clearing reaching for a gem while three purple slimes chase it">
  <div class="section-head">
    <h2>This game was built from a terminal</h2>
    <p>Gem Grove is one shell script of godot-cli commands plus six short GDScript files. Nobody opened the editor and nobody typed a line of scene text. <!-- demo:play -->Play it here, then read how each stage went in.<!-- /demo:play --><!-- demo:still -->Here is how each stage went in.<!-- /demo:still --></p>
  </div>

  <div class="demo-row">
    <div class="player">
      <!-- demo:play --><div class="screen poster">
        <img src="{{ base_url }}/assets/demo/4-play.webp?v={{ asset_hash }}" width="960" height="540" alt="Gem Grove in play">
        <button class="btn" type="button" data-demo="{{ base_url }}/demo/gem-grove/index.html">Play in your browser</button>
      </div><!-- /demo:play -->
      <!-- demo:still --><div class="screen">
        <img src="{{ base_url }}/assets/demo/3-hud.webp?v={{ asset_hash }}" width="960" height="540" alt="Gem Grove title screen">
      </div><!-- /demo:still -->
      <div class="player-bar">
        <span class="keys"><kbd>W</kbd><kbd>A</kbd><kbd>S</kbd><kbd>D</kbd></span>
        <span>or the arrow keys</span>
        <!-- demo:play --><span class="note">Loads on click. About 10 MB the first time.</span><!-- /demo:play -->
        <!-- demo:still --><span class="note">The title screen, as godot-cli captured it.</span><!-- /demo:still -->
      </div>
    </div>
    <ul class="stats">
      <li><b>8</b>scenes, every one passing scene validate</li>
      <li><b>13</b>signal connections, all in the scene files</li>
      <li><b>319</b>lines of GDScript, for the rules and the animation</li>
      <li class="zero"><b>0</b>lines of hand-written scene text</li>
    </ul>
  </div>

  <h3 class="stages-title">Four stages, and the frame godot-cli captured after each</h3>
  <ol class="stages">
    <li>
      <img src="{{ base_url }}/assets/demo/1-level.webp?v={{ asset_hash }}" width="960" height="540" loading="lazy" alt="Stage 1: the empty forest clearing">
      <div class="stage-body">
        <span class="chip sun">Stage 1</span>
        <strong>A project and a level</strong>
        <span>A new project.godot, WASD and arrow keys in the input map, and a level scene with its background.</span>
        <pre class="term">project new --name "Gem Grove"
project input apply</pre>
      </div>
    </li>
    <li>
      <img src="{{ base_url }}/assets/demo/2-actors.webp?v={{ asset_hash }}" width="960" height="540" loading="lazy" alt="Stage 2: gems, slimes and the robot placed in the clearing">
      <div class="stage-body">
        <span class="chip sun">Stage 2</span>
        <strong>Actors from the catalog</strong>
        <span>The robot, a gem and a slime are each their own scene. One patch places six gems and three slimes by catalog id.</span>
        <pre class="term">catalog add actors/gem.tscn
scene apply main.tscn --patch</pre>
      </div>
    </li>
    <li>
      <img src="{{ base_url }}/assets/demo/3-hud.webp?v={{ asset_hash }}" width="960" height="540" loading="lazy" alt="Stage 3: hearts, a score counter and a title card over the clearing">
      <div class="stage-body">
        <span class="chip sun">Stage 3</span>
        <strong>A HUD you can open in the editor</strong>
        <span>Hearts, score, title card and game over card: 22 nodes, fonts and style boxes in a single write.</span>
        <pre class="term">scene apply ui/hud.tscn --patch
scene instance add --catalog-id</pre>
      </div>
    </li>
    <li>
      <img src="{{ base_url }}/assets/demo/4-play.webp?v={{ asset_hash }}" width="960" height="540" loading="lazy" alt="Stage 4: the game in play with a score of 2 and a burst where a gem was picked up">
      <div class="stage-body">
        <span class="chip sun">Stage 4</span>
        <strong>Rules, then a test drive</strong>
        <span>The run clicks Play and steers the robot into two gems. The score reads 2, and the log has no errors.</span>
        <pre class="term">project run --click PlayButton@10
  --press move_right@20..55</pre>
      </div>
    </li>
  </ol>
  <a class="more" href="{{ base_url }}/how-to/build-gem-grove/">Read the build, stage by stage</a>
</section>

<div class="trust">
  <section class="wrap section">
    <div class="section-head">
      <h2>Why you can trust what it writes</h2>
      <p>Writing a scene Godot can open is a low bar. The bar here is writing the scene Godot itself would have saved, then proving the change works before anyone reviews it.</p>
    </div>
    <div class="bento">
      <div class="tile wide light">
        <div>
          <h3>It writes what the editor writes</h3>
          <p>On every push, Godot saves a fixture scene headless, godot-cli writes the same scene, and <code>cmp</code> compares the two files. The test runs against the current stable Godot releases and the newest prerelease. When it fails, the tool is wrong and the editor is right.</p>
          <p>No reformatted-by-tool noise in your diffs, and opening the project in the editor changes nothing.</p>
          <a href="{{ base_url }}/how-to/godot-compatibility/" style="color: inherit">Stay byte-compatible with Godot</a>
        </div>
        <div class="cmp" role="img" aria-label="A file Godot saved and the file godot-cli wrote, compared with cmp and found identical">
          <div class="cmp-file"><b>Godot saved</b><pre>[gd_scene format=3 uid=…]

[node name="Fixture"
  type="Node2D"
  unique_id=…]</pre></div>
          <div class="cmp-eq">cmp<span><svg aria-hidden="true" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="#1b1530" stroke-width="3.2" stroke-linecap="round"><path d="M5 9h14M5 15h14"/></svg></span></div>
          <div class="cmp-file ours"><b>godot-cli wrote</b><pre>[gd_scene format=3 uid=…]

[node name="Fixture"
  type="Node2D"
  unique_id=…]</pre></div>
        </div>
      </div>

      <div class="tile">
        <h3>It catches the typo before the run</h3>
        <p><code>scene validate</code> checks every value, signal and method against a table generated from Godot's own class reference. It reads your scripts too, so a connection to a method that does not exist fails here, not in the running game.</p>
        <pre class="term"><span class="kw">[err] property_type_mismatch:</span>
Control.visible is bool, and this
value is vector2</pre>
      </div>

      <div class="tile">
        <h3>One document, one write</h3>
        <p>A player is a node, a collision shape, a sprite and a texture reference. Send the whole change as one JSON document. If any step fails, the file on disk is untouched, and <code>--dry-run</code> shows the tree you would end up with.</p>
        <pre class="term">{ "recipe": <span class="hl">"player_2d"</span>,
  "parent": "/root/Main",
  "name": "Player",
  "texture": "res://art/player.png" }</pre>
      </div>

      <div class="tile wide">
        <div class="run-shot">
          <img src="{{ base_url }}/assets/demo/4-play.webp?v={{ asset_hash }}" width="960" height="540" loading="lazy" alt="The frame a project run returned">
          <pre class="term">"ok": <span class="p">true</span>,
"error_count": <span class="p">0</span></pre>
        </div>
        <div>
          <h3>Then it runs the game and looks</h3>
          <p><code>project run</code> imports the project, runs it, keeps the last frame and reads the log. It exits 1 on any <code>ERROR</code> line. It can click a button on a chosen frame or hold an input action, so an agent proves the wiring without test code in your game. Over MCP the frame comes back as an image.</p>
          <a href="{{ base_url }}/how-to/verify-a-change/">Verify a change by running the game</a>
        </div>
      </div>
    </div>
  </section>
</div>

<section class="wrap section duo">
  <div>
    <h2>It knows what you have already built</h2>
    <p>An agent starts each session knowing none of your parts, so it rebuilds your health bar out of raw nodes. A catalog manifest beside a scene says what it is for, and the agent instances it by id.</p>
    <div class="manifest">
      <span class="manifest-icon"><img src="{{ base_url }}/assets/demo/gem.png?v={{ asset_hash }}" alt=""></span>
      <dl>
        <dt>actors/gem</dt>
        <dd>A gem that emits <code>collected</code> when the player touches it</dd>
        <dd><b>When to use</b> Anything the player picks up for score</dd>
        <dd><b>Signals</b> collected</dd>
      </dl>
    </div>
    <a class="more" href="{{ base_url }}/how-to/your-own-components/">Teach an agent your sub-scenes</a>
  </div>
  <div>
    <h2>Built for agents, usable by hand</h2>
    <p><code>godot-cli mcp</code> serves every command as a tool for Claude Code, Cursor and OpenCode. In a shell, <code>--json</code> on any command returns one envelope with a stable exit code. For people there is help on everything, a man page, and completions for bash, zsh and fish.</p>
    <pre class="term"><span class="p">$</span> godot-cli scene validate main.tscn --project-root . --json
{ "ok": <span class="p">true</span>, "data": { … }, "messages": [], "failure": null }</pre>
    <a class="more" href="{{ base_url }}/how-to/agent-setup/">Set up an agent</a>
  </div>
</section>

<section class="wrap section">
  <div class="limits">
    <h2>What it is not</h2>
    <ul>
      <li>It is not a game engine. Running the game is handed to the Godot you already have installed.</li>
      <li>It does not read binary <code>.scn</code> or <code>.res</code> files.</li>
      <li>It will not replace the editor when you are nudging a sprite two pixels to the left by eye.</li>
      <li>Godot prereleases are tested on every push, as a check that does not block. A format change there shows up in our CI before it shows up in your project.</li>
    </ul>
  </div>
</section>

<section class="wrap section start">
  <div class="start-head">
    <img src="{{ base_url }}/assets/demo/player.png?v={{ asset_hash }}" width="256" height="256" alt="">
    <div>
      <h2>Install it and author a first scene</h2>
      <p>Two lines, then the getting started page walks you through a first scene.</p>
    </div>
  </div>
  <div class="install-box">
    <pre id="install-start"><span class="p">$</span> curl -fsSL https://raw.githubusercontent.com/unabated-games/godot-cli/main/install.sh | bash
<span class="p">$</span> source "$HOME/.godot-cli/env.sh"</pre>
    <button class="copy" type="button" data-copy="install-start" aria-label="Copy the install commands"><svg aria-hidden="true" viewBox="0 0 24 24" width="24" height="24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15V6a2 2 0 0 1 2-2h9"/></svg></button>
  </div>
  <ul class="cards">
    <li><a href="{{ base_url }}/getting-started/"><strong>Getting started</strong><span>Install, author a first scene, and learn when --project-root matters.</span></a></li>
    <li><a href="{{ base_url }}/how-to/build-gem-grove/"><strong>Build the demo game</strong><span>Gem Grove's build script, stage by stage, with the frame captured after each.</span></a></li>
    <li><a href="{{ base_url }}/how-to/agent-setup/"><strong>Set up an agent</strong><span>Install the skill, write the project rules, and spot when an agent drifts back to building nodes in code.</span></a></li>
    <li><a href="{{ base_url }}/how-to/your-own-components/"><strong>Teach an agent your sub-scenes</strong><span>From a scene on disk to an agent instancing it by id, every command shown with its output.</span></a></li>
    <li><a href="{{ base_url }}/how-to/refactor-a-project/"><strong>Refactor an existing project</strong><span>Extract a subtree, move files without stale paths, and check what your scripts still reach.</span></a></li>
    <li><a href="{{ base_url }}/reference/"><strong>Command reference</strong><span>Every command and option, generated from the binary's own command tree.</span></a></li>
  </ul>
</section>
