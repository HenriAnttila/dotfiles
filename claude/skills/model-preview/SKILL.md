---
name: model-preview
description: Show the user a 3D model in a live preview pane (meshview) beside this conversation in their tmux, opening the split if it isn't open yet, and keep it on what the conversation is about. Use when the user asks to see, show, preview or look at a model or mesh (a .glb, .gltf, .obj, .stl, .ply or .blend, or what is in Blender right now), when they name a part of a model to work on ("let's edit the chair", "the pillars look off"), and after you build, change or export a model so they can watch it update. Also gives you a way to check a model yourself with a rendered snapshot.
---

The user's tmux has `meshview`, a GPU model viewer that runs in a pane: the
model spins with its own orbit camera, and the user drives it with the mouse
and keys (1/2/3 solid, material, render; z wireframe; v views; q closes it).
It renders the file itself, not through Blender, and **watches the file**: once
the pane shows a file, re-exporting that file updates the pane. The viewer is
`~/dotfiles/tmux/scripts/meshview.py`.

## Show a model

```sh
~/.claude/skills/model-preview/scripts/show.sh <model file>
```

It reuses the meshview pane already in this tmux window (switching it to this
file if it showed another) or opens one as a split to the right, and leaves the
keyboard on this conversation. It prints the pane id. Files: .glb, .gltf, .obj,
.stl, .ply, and .blend (exported to .glb with headless Blender on every save,
which takes a few seconds).

Tell the user the preview is open, and that they click into the pane to drive
it and press q there to close it.

## Keep the preview on what you're talking about

When the user names a part to work on ("let's edit the chair", "fix the
pillars"), put it in focus without being asked, before you start on the code:

1. If no preview is open, or it shows a file without that part, show the file
   that has it (`show.sh`).
2. `meshview ctl objects` and find the objects that are that part. Names won't
   match the user's words (the chair may be `Seat_Base`, `Seat_Pads`, ...), so
   match by meaning, and ask only if two parts could be meant.
3. `meshview ctl frame <name or shared prefix>` flies to fit them and stops
   the spin; `meshview ctl mark <object>` when one piece is meant.
4. Say in a line what is in view ("the seat: base, pads, post, footrest").

Keep it there while you work: after each change, frame the part again so the
user sees it, and move the view when the conversation moves to another part.

## A model that only exists in Blender

What you build through the Blender MCP lives in the open Blender session, not a
file. Export it to a preview file and show that file; afterwards, re-run the
same export after each change and the pane updates without calling show.sh
again.

```python
import bpy, os
path = os.path.expanduser("~/.cache/meshview/<name>.glb")
os.makedirs(os.path.dirname(path), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=path, export_format="GLB", use_visible=True, export_apply=True)
```

Use `use_selection=True` instead of `use_visible=True` to show only the
selection. This preview export is not the project's real export: when the
project already exports the model somewhere, show that file rather than
writing over it with these settings.

## When the user points at something

Clicking the model (without dragging) picks a spot: a teal ring marks it and
the pane says what was picked. When the user says "this", "here", "that bit"
or "what I clicked" while a preview is open, read the click before answering:

```sh
meshview ctl click
```

It gives the object name, triangle index, the 3D point, and the camera at the
time, all in **Blender coordinates (Z up, file units)**, the same space you
work in through the Blender MCP. If the click is old or `null`, ask them to
click the spot.

## Driving the pane

`meshview ctl <command>` talks to the meshview pane in this tmux window and
prints JSON. Show, don't describe: when you explain a part, fly the camera to
it and mark it.

```sh
meshview ctl frame <name>          # fly to fit objects whose name contains <name>; no name: whole model
meshview ctl view top              # front back left right top bottom
meshview ctl look from=X,Y,Z at=X,Y,Z
meshview ctl orbit 45 10           # degrees; zoom 2 = twice as close
meshview ctl mark <name>|X,Y,Z     # gold ring where you mean; mark clear removes it
meshview ctl mode render           # solid material render; wire/grid/spin [on|off]
meshview ctl objects               # every object with tris and Blender-space bounds
meshview ctl state                 # mode, camera, click, mark, stats
meshview ctl snapshot /tmp/x.png   # exactly what the pane shows, to read yourself
meshview ctl help
```

Camera moves glide over about half a second so the user can follow them, and
stop the spin.

## A model built from a .blend by scripts

When a project builds its models with scripts that run in Blender, make changes
in the scripts, not in an exported file. To show a change without writing the
project's own files, export a preview from the .blend, optionally after running
scripts on it:

```sh
~/.claude/skills/model-preview/scripts/preview_build.sh <file.blend> [<script.py> ...] [arg ...]
~/.claude/skills/model-preview/scripts/show.sh ~/.cache/meshview/<name>.glb   # first time only
```

It opens the .blend in headless Blender, runs the scripts in order (args that
aren't .py files stay in `sys.argv` for them, and `--no-save` is added),
exports the visible scene to `~/.cache/meshview/<name>.glb` in the .blend's
own units and frame, and warns if the .blend's timestamp changed. A script that
saves without honouring `--no-save` would still write the .blend, so read a
script before passing it. The pane reloads when the preview file changes, so
after the first show only re-run `preview_build.sh`. Then point at what changed
with `meshview ctl frame` and `ctl mark`, and say what changed in words.

## The model over footage

When the model's project has solved footage cameras, `meshview ctl ref list`
lists the shots, and the pane can show the model through a shot's camera over
that frame:

```sh
meshview ctl ref <shot> <frame>          # shot name or part of it, frame number
meshview ctl ref style wire|ghost|model  # wireframe over the frame / half-shaded / model only
meshview ctl ref next | ref next shot | ref off
```

The user's keys: r footage on/off, [ ] frame, { } shot, o overlay style;
orbiting leaves it. A click in footage view picks through that camera. Only a
model exported in the same frame as the cameras lines up; a part exported at
the origin will look misplaced, so say that rather than calling it a mismatch.

## Checking a model yourself

You cannot see the pane. To look at the model, render a snapshot and read the
PNG:

```sh
meshview --snapshot /tmp/<name>.png --mode solid|material|render <model file>
```

For numbers, `meshview --stats <model file>` prints JSON: tris, verts,
objects, materials, size (x, y, z), unit, textures (each WxH) and
texture_bytes (GPU memory with mipmaps). The pane shows the same in its
top-left corner. "m" is the glTF convention; the file may use another unit.

## Closing it

`tmux kill-pane -t <pane id>`, only when the user asks.
