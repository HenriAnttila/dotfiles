# Runs inside headless Blender on a project .blend, never saving it:
#   blender -b <file.blend> --python preview_export.py -- <out.glb> [<script.py> ...] [arg ...]
# Each script runs in order on the open file, exec'd with its own __file__ as if run in a
# live Blender; args that aren't .py files stay in sys.argv for the scripts to read, and
# --no-save is added for scripts that check it. Then the visible scene is exported to
# <out.glb> in the .blend's own units and frame.
import os
import sys

import bpy

argv = sys.argv[sys.argv.index("--") + 1:]
out, rest = argv[0], argv[1:]
scripts = [a for a in rest if a.endswith(".py")]
sys.argv = [sys.argv[0], "--"] + [a for a in rest if not a.endswith(".py")] + ["--no-save"]
for path in scripts:
    path = os.path.abspath(path)
    print("PREVIEW running", path)
    exec(compile(open(path).read(), path, "exec"), {"__file__": path, "__name__": "preview"})
os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
bpy.ops.export_scene.gltf(filepath=out, export_format="GLB", use_visible=True, export_apply=True)
print("PREVIEW wrote", out)
