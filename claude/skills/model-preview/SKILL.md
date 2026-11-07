---
name: model-preview
description: Show the user a 3D model in a live preview pane (meshview) beside this conversation in their tmux, opening the split if it isn't open yet. Use when the user asks to see, show, preview or look at a model or mesh (a .glb, .gltf, .obj, .stl, .ply or .blend, or what is in Blender right now), and after you build, change or export a model in Blender so they can watch it update. Also gives you a way to check a model yourself with a rendered snapshot.
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
selection. This preview export is not the project's real export: when the model
has a .glb the project already exports (roblox-mesh-export), show that file
rather than writing over it with these settings.

## Checking a model yourself

You cannot see the pane. To look at the model, render a snapshot and read the
PNG:

```sh
meshview --snapshot /tmp/<name>.png --mode solid|material|render <model file>
```

For numbers, `meshview --stats <model file>` prints JSON: tris, verts,
objects, materials, size (x, y, z), unit, textures (each WxH) and
texture_bytes (GPU memory with mipmaps). The pane shows the same in its
top-left corner. The project's exports treat 1 stud as 1 metre, so a .glb's
"m" there is studs.

## Closing it

`tmux kill-pane -t <pane id>`, only when the user asks.
