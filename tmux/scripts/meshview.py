#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["moderngl", "numpy", "trimesh", "pillow", "scipy", "networkx"]
# ///
"""meshview: a 3D model preview that lives in a tmux pane.

    meshview MODEL            view MODEL in this pane
    meshview --split MODEL    open a tmux split beside this pane and view it there
    meshview --stats MODEL    print the model's statistics as JSON
    meshview ctl COMMAND ...  drive the meshview pane in this tmux window (see `ctl help`)
    meshview --snapshot OUT.png [--mode solid|material|render] MODEL
                              render one frame to a PNG and exit (no terminal)

MODEL is .glb/.gltf/.obj/.stl/.ply, or a .blend, which is exported to .glb with
headless Blender first. The file is watched: save it and the pane reloads.

The model is rendered by this script on the GPU (offscreen OpenGL), not by
Blender, and drawn in the pane with the kitty graphics protocol through tmux
using Unicode placeholders, so tmux keeps it in place across window switches.

Keys (also shown in the pane's bottom line):
  drag / h j k l / arrows   orbit          scroll / + -   zoom
  right-drag / H J K L      pan            f              frame the model
  1 2 3                     solid / material / render
  space                     spin on/off    z  wireframe   g  grid
  v                         front, right, top, back views      q  quit
  r                         footage view on/off: it plays like a show; any key pauses,
                            space plays, ← → frame, ↑ ↓ shot, s real shot on/off, o overlay
"""

import math
import os
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time
import tty
import zlib
import json
from pathlib import Path

import numpy as np

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
MODES = ["solid", "material", "render"]
SPIN_SPEED = math.radians(22)  # radians per second
LIVE_PIXELS = 1_400_000  # max pixels per frame while spinning or dragging
REF_FPS = 10  # footage view plays at the solved frames' own rate
FOV = math.radians(35)

# gallifrey palette (nvim/colors/gallifrey.lua)
BG_TOP = (0.040, 0.105, 0.115)
BG_BOTTOM = (0.012, 0.030, 0.036)
TEAL = "70;225;205"
FG = "185;214;211"
DIM = "63;105;102"
GOLD = "217;181;108"
PANEL_BG = "7;20;23"


# ─── math ────────────────────────────────────────────────────────────────────
def normalize(v):
    n = np.linalg.norm(v)
    return v / n if n > 0 else v


def perspective(fovy, aspect, near, far):
    f = 1 / math.tan(fovy / 2)
    return np.array(
        [
            [f / aspect, 0, 0, 0],
            [0, f, 0, 0],
            [0, 0, (far + near) / (near - far), 2 * far * near / (near - far)],
            [0, 0, -1, 0],
        ],
        dtype=np.float64,
    )


def ortho(l, r, b, t, n, f):
    return np.array(
        [
            [2 / (r - l), 0, 0, -(r + l) / (r - l)],
            [0, 2 / (t - b), 0, -(t + b) / (t - b)],
            [0, 0, -2 / (f - n), -(f + n) / (f - n)],
            [0, 0, 0, 1],
        ],
        dtype=np.float64,
    )


def look_at(eye, target, up):
    f = normalize(target - eye)
    s = normalize(np.cross(f, up))
    u = np.cross(s, f)
    m = np.identity(4)
    m[0, :3], m[1, :3], m[2, :3] = s, u, -f
    m[0, 3], m[1, 3], m[2, 3] = -s @ eye, -u @ eye, f @ eye
    return m


def gl(m):
    return np.ascontiguousarray(m.T, dtype="f4").tobytes()


# ─── model loading ───────────────────────────────────────────────────────────
class Part:
    """One draw call: interleaved vertices + indices + material."""

    def __init__(self, verts, faces, base, tex, metal, rough, name="", lo=None, hi=None):
        self.verts, self.faces = verts, faces
        self.base, self.tex, self.metal, self.rough = base, tex, metal, rough
        self.name, self.lo, self.hi = name, lo, hi  # lo/hi: bounds in file (glTF) coordinates
        self.tris = len(faces)


def load_model(path):
    import trimesh
    from trimesh.visual.material import PBRMaterial, SimpleMaterial

    scene = trimesh.load(str(path), force="scene", process=False)
    raw = []
    materials, textures = set(), {}  # textures: id -> (w, h)
    tex_slots = ("baseColorTexture", "normalTexture", "metallicRoughnessTexture",
                 "emissiveTexture", "occlusionTexture", "image")
    for node in scene.graph.nodes_geometry:
        T, gname = scene.graph[node]
        g = scene.geometry.get(gname)
        if not isinstance(g, trimesh.Trimesh) or len(g.faces) == 0:
            continue
        pos = g.vertices @ T[:3, :3].T + T[:3, 3]
        nmat = np.linalg.inv(T[:3, :3]).T
        nrm = g.vertex_normals @ nmat.T
        nrm /= np.maximum(np.linalg.norm(nrm, axis=1, keepdims=True), 1e-12)
        n = len(pos)
        uv = np.zeros((n, 2))
        col = np.ones((n, 4))
        base, tex, metal, rough = np.array([0.8, 0.8, 0.8, 1.0]), None, 0.0, 0.5
        vis = g.visual
        if vis.kind == "texture":
            if getattr(vis, "uv", None) is not None and len(vis.uv) == n:
                uv = np.asarray(vis.uv, dtype=np.float64)
            mat = vis.material
            if mat is not None:
                materials.add(id(mat))
                for slot in tex_slots:
                    img = getattr(mat, slot, None)
                    if img is not None and hasattr(img, "size"):
                        textures[id(img)] = img.size
            if isinstance(mat, PBRMaterial):
                if mat.baseColorFactor is not None:
                    b = np.asarray(mat.baseColorFactor, dtype=np.float64)
                    base = b / 255 if b.max() > 1 else b
                else:
                    base = np.ones(4)
                tex = mat.baseColorTexture
                metal = 1.0 if mat.metallicFactor is None else float(mat.metallicFactor)
                rough = 1.0 if mat.roughnessFactor is None else float(mat.roughnessFactor)
            elif isinstance(mat, SimpleMaterial):
                base = np.asarray(mat.diffuse, dtype=np.float64) / 255
                tex = mat.image
        elif vis.kind in ("vertex", "face"):
            col = np.asarray(vis.vertex_colors, dtype=np.float64)[:, :4] / 255
        name = str(node) if node != gname else str(gname)
        raw.append((pos, nrm, uv, col, np.asarray(g.faces, dtype=np.uint32), base, tex, metal, rough, name))
    if not raw:
        raise ValueError("no meshes in file")

    allpos = np.concatenate([r[0] for r in raw])
    lo, hi = allpos.min(0), allpos.max(0)
    center = (lo + hi) / 2
    radius = max(np.linalg.norm(hi - lo) / 2, 1e-9)
    parts = []
    for pos, nrm, uv, col, faces, base, tex, metal, rough, name in raw:
        p = (pos - center) / radius
        verts = np.hstack([p, nrm, uv, col]).astype("f4")
        parts.append(Part(verts, faces, base, tex, metal, rough, name, pos.min(0), pos.max(0)))
    ground = float(((lo - center) / radius)[1])
    stats = {
        "tris": sum(len(r[4]) for r in raw),
        "verts": sum(len(r[0]) for r in raw),
        "objects": len(raw),
        "materials": len(materials),
        "size": [float(x) for x in hi - lo],
        # glTF is in metres; other formats carry no unit
        "unit": "m" if Path(path).suffix.lower() in (".glb", ".gltf") else "",
        "textures": sorted(textures.values(), key=lambda wh: -wh[0] * wh[1]),
        # GPU memory as RGBA8 with a full mip chain (+1/3)
        "texture_bytes": int(sum(w * h * 4 * 4 / 3 for w, h in textures.values())),
    }
    return parts, ground, stats, (center, radius)


def export_blend(blend, out):
    """Start headless Blender exporting a .blend to .glb; returns the Popen."""
    expr = (
        "import bpy; bpy.ops.export_scene.gltf("
        f"filepath={str(out)!r}, export_format='GLB', use_visible=True, export_apply=True)"
    )
    return subprocess.Popen(
        [BLENDER, "-b", str(blend), "--python-expr", expr],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )


# ─── renderer ────────────────────────────────────────────────────────────────
MESH_VS = """
#version 410
in vec3 in_pos; in vec3 in_nrm; in vec2 in_uv; in vec4 in_col;
uniform mat4 u_vp; uniform mat4 u_light_vp; uniform float u_push;
out vec3 v_pos; out vec3 v_nrm; out vec2 v_uv; out vec4 v_col; out vec4 v_lpos;
void main() {
  v_pos = in_pos; v_nrm = in_nrm; v_uv = in_uv; v_col = in_col;
  v_lpos = u_light_vp * vec4(in_pos, 1.0);
  vec4 p = u_vp * vec4(in_pos, 1.0);
  p.z -= u_push * p.w;
  gl_Position = p;
}
"""

COMMON_FS = """
uniform sampler2D u_shadow;
float shadow_at(vec4 lpos, float bias) {
  vec3 p = lpos.xyz / lpos.w * 0.5 + 0.5;
  if (p.z > 1.0 || p.x < 0.0 || p.x > 1.0 || p.y < 0.0 || p.y > 1.0) return 1.0;
  vec2 t = 1.0 / vec2(textureSize(u_shadow, 0));
  float s = 0.0;
  for (int x = -2; x <= 2; x++)
    for (int y = -2; y <= 2; y++)
      s += (p.z - bias > texture(u_shadow, p.xy + vec2(x, y) * t * 1.5).r) ? 0.0 : 1.0;
  return s / 25.0;
}
vec3 aces(vec3 x) { return clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0); }
"""

MESH_FS = """
#version 410
in vec3 v_pos; in vec3 v_nrm; in vec2 v_uv; in vec4 v_col; in vec4 v_lpos;
uniform int u_mode;           // 0 solid, 1 material, 2 render, 3 wire
uniform vec3 u_eye; uniform mat3 u_view_rot; uniform vec3 u_key;
uniform vec4 u_base; uniform float u_metal; uniform float u_rough;
uniform bool u_has_tex; uniform sampler2D u_tex;
uniform vec4 u_wire;
out vec4 frag;
const vec3 SKY = vec3(0.50, 0.66, 0.70);
const vec3 GROUND = vec3(0.09, 0.08, 0.07);
""" + COMMON_FS + """
void main() {
  if (u_mode == 3) { frag = u_wire; return; }
  vec3 N = normalize(v_nrm);
  vec3 V = normalize(u_eye - v_pos);
  if (dot(N, V) < 0.0) N = -N;

  if (u_mode == 0) {
    // Workbench-style studio lighting: lights fixed to the view.
    vec3 n = normalize(u_view_rot * N);
    vec3 L1 = normalize(vec3(-0.5, 0.7, 0.6));
    vec3 L2 = normalize(vec3(0.8, 0.1, 0.4));
    vec3 L3 = normalize(vec3(0.0, 0.5, -1.0));
    float d = max(dot(n, L1), 0.0) * 0.75 + max(dot(n, L2), 0.0) * 0.25 + max(dot(n, L3), 0.0) * 0.30;
    vec3 amb = mix(vec3(0.09, 0.10, 0.11), vec3(0.26, 0.28, 0.30), 0.5 + 0.5 * n.y);
    float spec = pow(max(dot(n, normalize(L1 + vec3(0, 0, 1))), 0.0), 40.0) * 0.18;
    vec3 c = vec3(0.80) * (amb + d) + spec;
    frag = vec4(pow(c, vec3(0.9)), 1.0);
    return;
  }

  vec4 base = u_base * v_col;
  if (u_has_tex) { vec4 t = texture(u_tex, v_uv); t.rgb = pow(t.rgb, vec3(2.2)); base *= t; }
  if (base.a < 0.3) discard;
  vec3 A = base.rgb;
  float m = clamp(u_metal, 0.0, 1.0), r = clamp(u_rough, 0.05, 1.0);
  vec3 L = normalize(u_key), H = normalize(L + V);
  float NL = max(dot(N, L), 0.0), NV = max(dot(N, V), 1e-3), NH = max(dot(N, H), 0.0), VH = max(dot(V, H), 0.0);
  vec3 F0 = mix(vec3(0.04), A, m);
  float a = r * r, a2 = a * a;
  float D = a2 / (3.14159 * pow(NH * NH * (a2 - 1.0) + 1.0, 2.0));
  float k = (r + 1.0) * (r + 1.0) / 8.0;
  float G = (NL / (NL * (1.0 - k) + k)) * (NV / (NV * (1.0 - k) + k));
  vec3 F = F0 + (1.0 - F0) * pow(1.0 - VH, 5.0);
  vec3 spec = D * G * F / max(4.0 * NL * NV, 1e-3);
  vec3 kd = (1.0 - F) * (1.0 - m);
  float sh = (u_mode == 2) ? shadow_at(v_lpos, 0.002) : 1.0;
  vec3 direct = (kd * A / 3.14159 + spec) * vec3(1.0, 0.96, 0.90) * 3.2 * NL * sh;
  vec3 env = mix(GROUND, SKY, 0.5 + 0.5 * N.y);
  vec3 R = reflect(-V, N);
  vec3 envs = mix(GROUND, SKY, smoothstep(-0.2, 0.4, R.y));
  vec3 Fe = F0 + (max(vec3(1.0 - r), F0) - F0) * pow(1.0 - NV, 5.0);
  float ao = (u_mode == 2) ? mix(0.55, 1.0, sh) : 1.0;
  vec3 c = direct + (kd * A * env * 0.9 + Fe * envs * mix(0.9, 0.12, r)) * ao;
  frag = vec4(pow(aces(c), vec3(1.0 / 2.2)), 1.0);
}
"""

BG_VS = """
#version 410
out vec2 v_uv;
void main() {
  vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
  v_uv = p;
  gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
}
"""

BG_FS = """
#version 410
in vec2 v_uv;
uniform vec3 u_top; uniform vec3 u_bottom;
out vec4 frag;
void main() {
  vec3 c = mix(u_bottom, u_top, smoothstep(0.0, 1.0, v_uv.y));
  float vig = 1.0 - 0.35 * dot(v_uv - 0.5, v_uv - 0.5) * 2.0;
  frag = vec4(c * vig, 1.0);
}
"""

GROUND_VS = """
#version 410
in vec3 in_pos;
uniform mat4 u_vp; uniform mat4 u_light_vp;
out vec3 v_pos; out vec4 v_lpos;
void main() {
  v_pos = in_pos;
  v_lpos = u_light_vp * vec4(in_pos, 1.0);
  gl_Position = u_vp * vec4(in_pos, 1.0);
}
"""

GROUND_FS = """
#version 410
in vec3 v_pos; in vec4 v_lpos;
uniform int u_mode; uniform bool u_grid; uniform float u_cell;
out vec4 frag;
""" + COMMON_FS + """
void main() {
  float dist = length(v_pos.xz);
  vec3 col = vec3(0.0);
  float alpha = 0.0;
  if (u_grid) {
    float fade = 1.0 - smoothstep(1.2, 5.0, dist);
    vec2 g = v_pos.xz / u_cell;
    vec2 w = fwidth(g);
    vec2 l = abs(fract(g - 0.5) - 0.5) / max(w, vec2(1e-5));
    float line = 1.0 - min(min(l.x, l.y), 1.0);
    vec2 la = abs(v_pos.xz) / max(fwidth(v_pos.xz), vec2(1e-5));
    float axis_x = 1.0 - min(la.y, 1.0);  // the x axis runs where z = 0
    float axis_z = 1.0 - min(la.x, 1.0);
    col = vec3(0.30, 0.52, 0.52);
    alpha = line * 0.22 * fade;
    if (axis_x > 0.0) { col = mix(col, vec3(0.75, 0.30, 0.32), axis_x); alpha = max(alpha, axis_x * 0.5 * fade); }
    if (axis_z > 0.0) { col = mix(col, vec3(0.30, 0.50, 0.80), axis_z); alpha = max(alpha, axis_z * 0.5 * fade); }
  }
  if (u_mode == 2) {
    float s = shadow_at(v_lpos, 0.003);
    float a = (1.0 - s) * 0.65 * (1.0 - smoothstep(0.8, 3.0, dist));
    col = mix(col, vec3(0.0), a / max(alpha + a, 1e-4));
    alpha = max(alpha, a);
  }
  if (alpha < 0.003) discard;
  frag = vec4(col, alpha);
}
"""

DEPTH_VS = """
#version 410
in vec3 in_pos;
uniform mat4 u_light_vp;
void main() { gl_Position = u_light_vp * vec4(in_pos, 1.0); }
"""

DEPTH_FS = """
#version 410
void main() {}
"""

PICK_VS = """
#version 410
in vec3 in_pos;
uniform mat4 u_vp;
void main() { gl_Position = u_vp * vec4(in_pos, 1.0); }
"""

PICK_FS = """
#version 410
uniform uint u_part;
out uvec2 frag;
void main() { frag = uvec2(u_part, uint(gl_PrimitiveID)); }
"""

# Marker rings drawn over the frame at projected points: the user's click
# (teal) and the spot Claude points at (gold).
MARK_FS = """
#version 410
uniform vec2 u_px; uniform float u_r; uniform vec3 u_col;
out vec4 frag;
void main() {
  float d = length(gl_FragCoord.xy - u_px);
  float ring = 1.0 - smoothstep(1.0, 2.2, abs(d - u_r));
  float halo = (1.0 - smoothstep(u_r, u_r * 2.2, d)) * 0.25;
  float dot_ = 1.0 - smoothstep(1.5, 3.0, d);
  float a = max(max(ring, dot_), halo);
  if (a < 0.01) discard;
  frag = vec4(u_col, a);
}
"""


class Renderer:
    def __init__(self):
        import moderngl

        self.mgl = moderngl
        self.ctx = moderngl.create_standalone_context(require=410)
        c = self.ctx
        self.mesh_prog = c.program(vertex_shader=MESH_VS, fragment_shader=MESH_FS)
        self.bg_prog = c.program(vertex_shader=BG_VS, fragment_shader=BG_FS)
        self.ground_prog = c.program(vertex_shader=GROUND_VS, fragment_shader=GROUND_FS)
        self.depth_prog = c.program(vertex_shader=DEPTH_VS, fragment_shader=DEPTH_FS)
        self.bg_vao = c.vertex_array(self.bg_prog, [])
        self.pick_prog = c.program(vertex_shader=PICK_VS, fragment_shader=PICK_FS)
        self.mark_prog = c.program(vertex_shader=BG_VS, fragment_shader=MARK_FS)
        self.mark_vao = c.vertex_array(self.mark_prog, [])
        self.pick_size = None
        self.shadow_tex = c.depth_texture((2048, 2048))
        self.shadow_tex.compare_func = ""
        self.shadow_tex.repeat_x = self.shadow_tex.repeat_y = False
        self.shadow_fbo = c.framebuffer(depth_attachment=self.shadow_tex)
        self.white = c.texture((1, 1), 4, b"\xff\xff\xff\xff")
        self.max_samples = min(8, c.max_samples)
        self.size = None
        self.parts = []
        self.ground_vao = None

    def set(self, prog, name, value):
        if name in prog:
            u = prog[name]
            if isinstance(value, (bytes, bytearray)):
                u.write(value)
            else:
                u.value = value

    def upload(self, parts, ground):
        for p in self.parts:
            p.vao.release()
            p.vbo.release()
            p.ibo.release()
            if p.gltex is not None:
                p.gltex.release()
        c = self.ctx
        for p in parts:
            p.vbo = c.buffer(p.verts.tobytes())
            p.ibo = c.buffer(p.faces.astype("u4").tobytes())
            p.vao = c.vertex_array(
                self.mesh_prog,
                [(p.vbo, "3f 3f 2f 4f", "in_pos", "in_nrm", "in_uv", "in_col")],
                index_buffer=p.ibo,
                index_element_size=4,
            )
            p.depth_vao = c.vertex_array(
                self.depth_prog, [(p.vbo, "3f 36x", "in_pos")], index_buffer=p.ibo, index_element_size=4
            )
            p.pick_vao = c.vertex_array(
                self.pick_prog, [(p.vbo, "3f 36x", "in_pos")], index_buffer=p.ibo, index_element_size=4
            )
            p.gltex = None
            if p.tex is not None:
                img = p.tex.convert("RGBA").transpose(1)  # trimesh gives bottom-left UVs; GL rows start at the bottom
                p.gltex = c.texture(img.size, 4, img.tobytes())
                p.gltex.build_mipmaps()
                p.gltex.filter = (self.mgl.LINEAR_MIPMAP_LINEAR, self.mgl.LINEAR)
                p.gltex.anisotropy = 8.0
            p.verts = None  # uploaded; free the CPU copy
        self.parts = parts
        y = ground - 0.002
        s = 12.0
        quad = np.array([[-s, y, -s], [s, y, -s], [s, y, s], [-s, y, -s], [s, y, s], [-s, y, s]], dtype="f4")
        if self.ground_vao is not None:
            self.ground_vao.release()
        self.ground_vbo = c.buffer(quad.tobytes())
        self.ground_vao = c.vertex_array(self.ground_prog, [(self.ground_vbo, "3f", "in_pos")])

    def ensure_size(self, w, h, samples):
        key = (w, h, samples)
        if self.size == key:
            return
        c = self.ctx
        self.ms_fbo = c.framebuffer(
            color_attachments=[c.renderbuffer((w, h), 4, samples=samples)],
            depth_attachment=c.depth_renderbuffer((w, h), samples=samples),
        )
        self.out_fbo = c.framebuffer(color_attachments=[c.renderbuffer((w, h), 4)])
        self.size = key

    @staticmethod
    def matrices(cam, w, h):
        eye = cam.eye()
        view = look_at(eye, cam.target, np.array([0.0, 1.0, 0.0]))
        proj = perspective(FOV, w / h, 0.02 * cam.dist, 40.0 + cam.dist * 4)
        return eye, view, proj @ view

    def id_depth(self, w, h, override):
        """Every pixel's part (0 = background) and its distance from the camera, top row first."""
        c = self.ctx
        if self.pick_size != (w, h):
            self.pick_ids = c.texture((w, h), 2, dtype="u4")
            self.pick_depth = c.depth_texture((w, h))
            self.pick_fbo = c.framebuffer(color_attachments=[self.pick_ids], depth_attachment=self.pick_depth)
            self.pick_size = (w, h)
        _, view, vp = override
        self.pick_fbo.use()
        c.viewport = (0, 0, w, h)
        self.pick_fbo.clear(0, 0, 0, 0, depth=1.0)
        c.enable(self.mgl.DEPTH_TEST)
        c.disable(self.mgl.BLEND)
        self.set(self.pick_prog, "u_vp", gl(vp))
        for i, p in enumerate(self.parts):
            self.set(self.pick_prog, "u_part", i + 1)
            p.pick_vao.render()
        ids = np.frombuffer(self.pick_fbo.read(components=2, dtype="u4"), dtype=np.uint32).reshape(h, w, 2)[::-1, :, 0]
        z = np.frombuffer(self.pick_fbo.read(components=1, attachment=-1, dtype="f4"), dtype=np.float32).reshape(h, w)[::-1]
        # depth buffer -> distance along the view: invert the projection's z (P[2,2], P[2,3])
        proj = vp @ np.linalg.inv(view)
        a, b = proj[2, 2], proj[2, 3]
        ndc = z * 2.0 - 1.0
        # z_clip = a*z + b, w_clip = -z  ->  ndc = -(a*z + b)/z  ->  distance -z = b / (ndc + a)
        den = ndc + a
        dist = np.abs(b / np.where(np.abs(den) < 1e-9, -1e-9, den))
        return ids, np.where(ids > 0, dist, np.inf)

    def outlines(self, w, h, override):
        """Thin lines where the picture changes for real: the silhouette, where one part meets
        another, and where a surface folds away (a jump in distance). RGBA, top row first."""
        ids, dist = self.id_depth(w, h, override)
        edge = np.zeros((h, w), dtype=bool)
        for dy, dx in ((0, 1), (1, 0)):
            a_ids, b_ids = ids[: h - dy, : w - dx], ids[dy:, dx:]
            a_d, b_d = dist[: h - dy, : w - dx], dist[dy:, dx:]
            both = np.isfinite(a_d) & np.isfinite(b_d)  # background is infinitely far: no jump to measure there
            with np.errstate(invalid="ignore"):
                jump = both & (np.abs(np.where(both, a_d, 0) - np.where(both, b_d, 0)) > 0.04 * np.where(both, np.minimum(a_d, b_d), 1))
            e = (a_ids != b_ids) | jump
            edge[: h - dy, : w - dx] |= e
        out = np.zeros((h, w, 4), dtype=np.uint8)
        out[edge] = (70, 245, 220, 255)
        return out

    def pick(self, cam, w, h, px, py, override=None):
        """What is under pixel (px, py), top-left origin: (part index, triangle, point) or None."""
        c = self.ctx
        if self.pick_size != (w, h):
            self.pick_ids = c.texture((w, h), 2, dtype="u4")
            self.pick_depth = c.depth_texture((w, h))
            self.pick_fbo = c.framebuffer(color_attachments=[self.pick_ids], depth_attachment=self.pick_depth)
            self.pick_size = (w, h)
        _, _, vp = override or self.matrices(cam, w, h)
        self.pick_fbo.use()
        c.viewport = (0, 0, w, h)
        self.pick_fbo.clear(0, 0, 0, 0, depth=1.0)
        c.enable(self.mgl.DEPTH_TEST)
        c.disable(self.mgl.BLEND)
        self.set(self.pick_prog, "u_vp", gl(vp))
        for i, p in enumerate(self.parts):
            self.set(self.pick_prog, "u_part", i + 1)
            p.pick_vao.render()
        gy = h - 1 - py
        ids = np.frombuffer(self.pick_fbo.read(viewport=(px, gy, 1, 1), components=2, dtype="u4"), dtype=np.uint32)
        if ids[0] == 0:
            return None
        depth = np.frombuffer(
            self.pick_fbo.read(viewport=(px, gy, 1, 1), components=1, attachment=-1, dtype="f4"), dtype=np.float32
        )[0]
        ndc = np.array([2 * (px + 0.5) / w - 1, 2 * (gy + 0.5) / h - 1, 2 * depth - 1, 1.0])
        world = np.linalg.inv(vp) @ ndc
        return int(ids[0]) - 1, int(ids[1]), world[:3] / world[3]

    def render(self, cam, mode, w, h, wire, grid, quality, markers=(), override=None, layer=None):
        """The frame as RGB. override: (eye, view, vp) for a camera not from `cam` (reference
        footage). layer: "wire" (hidden-line wireframe only) or "shaded" gives RGBA on a
        transparent background, with no floor, for laying over footage."""
        mgl, c = self.mgl, self.ctx
        samples = self.max_samples if quality else min(4, self.max_samples)
        self.ensure_size(w, h, samples)
        eye, view, vp = override or self.matrices(cam, w, h)
        if layer:
            grid = False
        key = normalize(np.array([0.45, 0.85, 0.35]))
        lview = look_at(key * 4.0, np.zeros(3), np.array([0.0, 0.0, 1.0]) if abs(key[1]) > 0.99 else np.array([0.0, 1.0, 0.0]))
        light_vp = ortho(-1.7, 1.7, -1.7, 1.7, 0.5, 8.0) @ lview

        use_shadow = mode == 2
        if use_shadow:
            self.shadow_fbo.use()
            c.clear(depth=1.0)
            c.enable(mgl.DEPTH_TEST)
            c.disable(mgl.BLEND)
            self.set(self.depth_prog, "u_light_vp", gl(light_vp))
            for p in self.parts:
                p.depth_vao.render()

        self.ms_fbo.use()
        c.viewport = (0, 0, w, h)
        c.clear(0, 0, 0, 0 if layer else 1, depth=1.0)
        c.disable(mgl.DEPTH_TEST)
        if not layer:
            self.set(self.bg_prog, "u_top", BG_TOP)
            self.set(self.bg_prog, "u_bottom", BG_BOTTOM)
            self.bg_vao.render(mgl.TRIANGLES, vertices=3)

        c.enable(mgl.DEPTH_TEST)
        c.disable(mgl.CULL_FACE)
        mp = self.mesh_prog
        self.set(mp, "u_vp", gl(vp))
        self.set(mp, "u_light_vp", gl(light_vp))
        self.set(mp, "u_eye", tuple(eye))
        self.set(mp, "u_view_rot", np.ascontiguousarray(view[:3, :3].T, dtype="f4").tobytes())
        self.set(mp, "u_key", tuple(key))
        self.set(mp, "u_mode", mode)
        self.set(mp, "u_push", 0.0)
        self.set(mp, "u_tex", 0)
        self.set(mp, "u_shadow", 1)
        self.shadow_tex.use(location=1)
        if layer == "wire":  # depth only, so the wireframe hides what's behind the model
            c.enable(mgl.BLEND)
            c.blend_func = mgl.ZERO, mgl.ONE
        for p in self.parts:
            self.set(mp, "u_base", tuple(float(x) for x in p.base))
            self.set(mp, "u_metal", p.metal)
            self.set(mp, "u_rough", p.rough)
            self.set(mp, "u_has_tex", p.gltex is not None)
            (p.gltex or self.white).use(location=0)
            p.vao.render()

        c.disable(mgl.BLEND)
        if wire or layer == "wire":
            c.wireframe = True
            self.set(mp, "u_mode", 3)
            self.set(mp, "u_push", 0.0008)
            self.set(mp, "u_wire", (0.27, 0.88, 0.80, 1.0) if mode == 0 or layer == "wire" else (0.02, 0.06, 0.07, 1.0))
            for p in self.parts:
                p.vao.render()
            c.wireframe = False

        if grid or use_shadow:
            c.enable(mgl.BLEND)
            c.blend_func = mgl.SRC_ALPHA, mgl.ONE_MINUS_SRC_ALPHA
            gp = self.ground_prog
            self.set(gp, "u_vp", gl(vp))
            self.set(gp, "u_light_vp", gl(light_vp))
            self.set(gp, "u_mode", mode)
            self.set(gp, "u_grid", grid)
            self.set(gp, "u_cell", 0.25)
            self.set(gp, "u_shadow", 1)
            self.shadow_tex.use(location=1)
            self.ground_vao.render()
            c.disable(mgl.BLEND)

        if markers:
            c.disable(mgl.DEPTH_TEST)
            c.enable(mgl.BLEND)
            c.blend_func = mgl.SRC_ALPHA, mgl.ONE_MINUS_SRC_ALPHA
            for pos, col in markers:
                clip = vp @ np.append(pos, 1.0)
                if clip[3] <= 0:
                    continue
                ndc = clip[:3] / clip[3]
                self.set(self.mark_prog, "u_px", ((ndc[0] * 0.5 + 0.5) * w, (ndc[1] * 0.5 + 0.5) * h))
                self.set(self.mark_prog, "u_r", max(6.0, h / 70))
                self.set(self.mark_prog, "u_col", col)
                self.mark_vao.render(mgl.TRIANGLES, vertices=3)
            c.disable(mgl.BLEND)

        c.copy_framebuffer(self.out_fbo, self.ms_fbo)
        n = 4 if layer else 3
        data = self.out_fbo.read(components=n, alignment=1)
        img = np.frombuffer(data, dtype=np.uint8).reshape(h, w, n)[::-1]
        return np.ascontiguousarray(img)


# ─── camera ──────────────────────────────────────────────────────────────────
VIEWS = [("front", 0.0, 0.0), ("right", math.pi / 2, 0.0), ("top", 0.0, math.pi / 2 - 1e-3), ("back", math.pi, 0.0)]


class Camera:
    def __init__(self):
        self.reset()

    def reset(self):
        self.target = np.zeros(3)
        self.yaw = math.radians(35)
        self.pitch = math.radians(18)
        self.dist = 1.15 / math.sin(FOV / 2)

    def eye(self):
        cp = math.cos(self.pitch)
        return self.target + self.dist * np.array(
            [cp * math.sin(self.yaw), math.sin(self.pitch), cp * math.cos(self.yaw)]
        )

    def orbit(self, dyaw, dpitch):
        self.yaw += dyaw
        self.pitch = max(-math.pi / 2 + 1e-3, min(math.pi / 2 - 1e-3, self.pitch + dpitch))

    def zoom(self, factor):
        self.dist = max(0.05, min(50.0, self.dist * factor))

    def state(self):
        return (self.yaw, self.pitch, self.dist, self.target.copy())

    def fly_to(self, yaw=None, pitch=None, dist=None, target=None, duration=0.6):
        """Glide to a new view instead of jumping, so the user can follow it."""
        y0, p0, d0, t0 = self.state()
        y1 = y0 if yaw is None else yaw
        y1 = y0 + (y1 - y0 + math.pi) % (2 * math.pi) - math.pi  # shortest way round
        p1 = p0 if pitch is None else max(-math.pi / 2 + 1e-3, min(math.pi / 2 - 1e-3, pitch))
        d1 = d0 if dist is None else max(0.05, min(50.0, dist))
        t1 = t0 if target is None else np.asarray(target, dtype=np.float64)
        self.anim = (time.time(), duration, (y0, p0, d0, t0), (y1, p1, d1, t1))

    def step(self):
        """Advance a flight; True while one is running."""
        anim = getattr(self, "anim", None)
        if not anim:
            return False
        start, dur, a, b = anim
        t = min(1.0, (time.time() - start) / dur)
        k = t * t * (3 - 2 * t)
        self.yaw, self.pitch = a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k
        self.dist = a[2] * (b[2] / a[2]) ** k
        self.target = a[3] + (b[3] - a[3]) * k
        if t >= 1.0:
            self.anim = None
        return True

    def pan(self, dx, dy):
        fwd = normalize(self.target - self.eye())
        right = normalize(np.cross(fwd, [0.0, 1.0, 0.0]))
        up = np.cross(right, fwd)
        s = self.dist * 0.6
        self.target = self.target + (-right * dx + up * dy) * s


# ─── terminal output: kitty graphics through tmux ────────────────────────────
DIACRITICS = [int(x, 16) for x in (
    "0305 030D 030E 0310 0312 033D 033E 033F 0346 034A 034B 034C 0350 0351 0352 0357 035B 0363 0364 0365 "
    "0366 0367 0368 0369 036A 036B 036C 036D 036E 036F 0483 0484 0485 0486 0487 0592 0593 0594 0595 0597 "
    "0598 0599 059C 059D 059E 059F 05A0 05A1 05A8 05A9 05AB 05AC 05AF 05C4 0610 0611 0612 0613 0614 0615 "
    "0616 0617 0657 0658 0659 065A 065B 065D 065E 06D6 06D7 06D8 06D9 06DA 06DB 06DC 06DF 06E0 06E1 06E2 "
    "06E4 06E7 06E8 06EB 06EC 0730 0732 0733 0735 0736 073A 073D 073F 0740 0741 0743 0745 0747 0749 074A "
    "07EB 07EC 07ED 07EE 07EF 07F0 07F1 07F3 0816 0817 0818 0819 081B 081C 081D 081E 081F 0820 0821 0822 "
    "0823 0825 0826 0827 0829 082A 082B 082C 082D 0951 0953 0954 0F82 0F83 0F86 0F87 135D 135E 135F 17DD "
    "193A 1A17 1A75 1A76 1A77 1A78 1A79 1A7A 1A7B 1A7C 1B6B 1B6D 1B6E 1B6F 1B70 1B71 1B72 1B73 1CD0 1CD1 "
    "1CD2 1CDA 1CDB 1CE0 1DC0 1DC1 1DC3 1DC4 1DC5 1DC6 1DC7 1DC8 1DC9 1DCB 1DCC 1DD1 1DD2 1DD3 1DD4 1DD5 "
    "1DD6 1DD7 1DD8 1DD9 1DDA 1DDB 1DDC 1DDD 1DDE 1DDF 1DE0 1DE1 1DE2 1DE3 1DE4 1DE5 1DE6 1DFE 20D0 20D1 "
    "20D4 20D5 20D6 20D7 20DB 20DC 20E1 20E7 20E9 20F0"
).split()]
PLACEHOLDER = "\U0010EEEE"
# One image id for the pane's whole life. Each frame re-sends the image under
# it; the placeholder grid (plain text to tmux) is drawn once per size. Redrawing
# the grid every frame was ~56 KB of pane output per frame, which makes tmux
# throttle the pane and drop most of the image passthroughs.
IMAGE_ID = 0x4D5601 + (os.getpid() % 200) * 2


class Screen:
    def __init__(self, out):
        self.out = out
        self.in_tmux = bool(os.environ.get("TMUX"))
        self.tmpdir = tempfile.gettempdir()
        self.frame = 0
        self.grid = None  # (cols, rows) the placeholder grid was drawn for
        self.files = []  # temp frames we wrote; the terminal deletes them once read

    def wrap(self, seq):
        if self.in_tmux:
            return "\x1bPtmux;" + seq.replace("\x1b", "\x1b\x1b") + "\x1b\\"
        return seq

    def write(self, s):
        self.out.write(s)
        self.out.flush()

    def size(self):
        """(cols, rows, cell_w, cell_h) in characters and pixels."""
        buf = struct.unpack("HHHH", __import__("fcntl").ioctl(self.out.fileno(), termios.TIOCGWINSZ, b"\0" * 8))
        rows, cols, xpix, ypix = buf
        cw, ch = (xpix / cols, ypix / rows) if xpix and ypix else (0, 0)
        if not cw and self.in_tmux:
            try:
                r = subprocess.run(
                    ["tmux", "display", "-p", "#{client_cell_width} #{client_cell_height}"],
                    capture_output=True, text=True, timeout=1,
                )
                cw, ch = (float(x) for x in r.stdout.split())
            except Exception:
                pass
        if not cw:
            cw, ch = 9.0, 20.0
        return cols, rows, cw, ch

    def show(self, img, cols, rows):
        """Send an RGB frame and lay the placeholder grid over cols x rows cells."""
        import base64

        h, w, _ = img.shape
        self.frame += 1
        path = os.path.join(self.tmpdir, f"tty-graphics-protocol-meshview-{os.getpid()}-{self.frame}.rgb")
        with open(path, "wb") as f:
            f.write(zlib.compress(img.tobytes(), 1))
        self.files.append((time.time(), path))
        payload = base64.b64encode(path.encode()).decode()
        if self.grid != (cols, rows):
            # The pane changed size. Re-sending the image under the same id keeps its
            # old placement (old cols x rows) in Ghostty, which then fits the new frame
            # into the old box: bands of bare background. Drop the image first.
            self.write(self.wrap(f"\x1b_Ga=d,d=I,i={IMAGE_ID},q=2\x1b\\"))
        self.write(self.wrap(
            f"\x1b_Ga=T,t=t,f=24,o=z,s={w},v={h},i={IMAGE_ID},U=1,c={cols},r={rows},q=2;{payload}\x1b\\"
        ))
        if self.grid != (cols, rows):
            self.draw_grid(cols, rows)
        self.sweep(2.0)

    def draw_grid(self, cols, rows):
        r, g, b = (IMAGE_ID >> 16) & 255, (IMAGE_ID >> 8) & 255, IMAGE_ID & 255
        lines = []
        for row in range(min(rows, len(DIACRITICS))):
            rd = chr(DIACRITICS[row])
            lines.append(
                f"\x1b[{row + 1};1H\x1b[38;2;{r};{g};{b}m"
                + "".join(PLACEHOLDER + rd + chr(DIACRITICS[c]) for c in range(min(cols, len(DIACRITICS))))
            )
        self.write("".join(lines) + "\x1b[0m")
        self.grid = (cols, rows)

    def sweep(self, age):
        """Remove frames the terminal never picked up (dropped by tmux, or no kitty support)."""
        now, keep = time.time(), []
        for t, path in self.files:
            if now - t >= age:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
            else:
                keep.append((t, path))
        self.files = keep

    def status(self, row, cols, text):
        # autowrap off while writing: a row one column too wide would otherwise wrap,
        # scroll the whole pane up a line and lose the row
        self.write(f"\x1b[?7l\x1b[{row};1H\x1b[2K{text}\x1b[0m\x1b[?7h")

    def cleanup(self):
        self.write(self.wrap(f"\x1b_Ga=d,d=I,i={IMAGE_ID},q=2\x1b\\"))
        self.sweep(0)


# ─── input ───────────────────────────────────────────────────────────────────
def parse_input(buf):
    """Split raw bytes into events: ('key', str) or ('mouse', btn, x, y, pressed)."""
    events, i = [], 0
    s = buf.decode("utf-8", "ignore")
    while i < len(s):
        ch = s[i]
        if ch == "\x1b":
            if s.startswith("\x1b[<", i):
                j = i + 3
                while j < len(s) and s[j] not in "Mm":
                    j += 1
                if j < len(s):
                    try:
                        b, x, y = (int(v) for v in s[i + 3 : j].split(";"))
                        events.append(("mouse", b, x, y, s[j] == "M"))
                    except ValueError:
                        pass
                    i = j + 1
                    continue
            if s.startswith("\x1b[", i) and i + 2 < len(s):
                code = s[i + 2]
                names = {"A": "up", "B": "down", "C": "right", "D": "left"}
                if code in names:
                    events.append(("key", names[code]))
                    i += 3
                    continue
                j = i + 2
                while j < len(s) and not s[j].isalpha() and s[j] != "~":
                    j += 1
                i = j + 1
                continue
            events.append(("key", "esc"))
            i += 1
            continue
        events.append(("key", ch))
        i += 1
    return events


# ─── reference footage: solved show cameras ──────────────────────────────────
# A project's placed shots (the coral room's observations/place/<shot>/): a COLMAP
# solve of the footage (solve/radial/*.bin, frames in solve/images/) and a
# placement.json putting the build frame (Blender: metres, Z up) into the solve
# frame: X_solve = e^logscale * R(rotvec) * Rz(turn_deg) * X_build + shift
# (Coral tools/shot3d.py to_solve). The cameras are in metres; a project's .glb
# exports are in Roblox studs (build_room.py: 1 stud = 0.28 m).
STUD_M = 0.28


def find_refs(model):
    """The placed shots for a model: observations/place in it or a folder above it."""
    env = os.environ.get("MESHVIEW_REFS")
    for d in ([Path(env)] if env else []) + [p / "observations" / "place" for p in Path(model).resolve().parents]:
        shots = shots_in(d)
        if shots:
            return shots
    return []


def shots_in(d):
    d = Path(d).expanduser()
    if not d.is_dir():
        return []
    return sorted(x for x in d.iterdir() if (x / "placement.json").exists() and (x / "solve" / "radial").is_dir())


def read_colmap(d):
    """COLMAP binary cameras + images: K (f, cx, cy, k1, k2), (w, h), [(name, R, t)] by name."""
    b = (d / "cameras.bin").read_bytes()
    _, model, w, h = struct.unpack_from("<iiQQ", b, 8)
    params = struct.unpack_from(f"<{(len(b) - 32) // 8}d", b, 32)
    if model == 2:  # SIMPLE_RADIAL
        K = dict(f=params[0], cx=params[1], cy=params[2], k1=params[3], k2=0.0)
    elif model == 3:  # RADIAL
        K = dict(f=params[0], cx=params[1], cy=params[2], k1=params[3], k2=params[4])
    else:
        raise ValueError(f"camera model {model} not handled")
    b = (d / "images.bin").read_bytes()
    n, o, frames = struct.unpack_from("<Q", b, 0)[0], 8, []
    for _ in range(n):
        qw, qx, qy, qz = struct.unpack_from("<4d", b, o + 4)
        t = np.array(struct.unpack_from("<3d", b, o + 36))
        o += 64
        e = b.index(b"\0", o)
        name = b[o:e].decode()
        o = e + 1
        o += 8 + struct.unpack_from("<Q", b, o)[0] * 24
        R = np.array([
            [1 - 2 * (qy * qy + qz * qz), 2 * (qx * qy - qw * qz), 2 * (qx * qz + qw * qy)],
            [2 * (qx * qy + qw * qz), 1 - 2 * (qx * qx + qz * qz), 2 * (qy * qz - qw * qx)],
            [2 * (qx * qz - qw * qy), 2 * (qy * qz + qw * qx), 1 - 2 * (qx * qx + qy * qy)],
        ])
        frames.append((name, R, t))
    return K, (w, h), sorted(frames, key=lambda f: f[0])


class RefShot:
    def __init__(self, path):
        from scipy.spatial.transform import Rotation

        self.path, self.name = path, path.name
        P = json.loads((path / "placement.json").read_text())
        x = np.asarray(P["x"], dtype=np.float64)
        self.K, self.size, self.frames = read_colmap(path / "solve" / "radial")
        turn = math.radians(float(P["turn_deg"]))
        Rz = np.array([[math.cos(turn), -math.sin(turn), 0], [math.sin(turn), math.cos(turn), 0], [0, 0, 1]])
        self.Rp, self.shift, self.scale = Rotation.from_rotvec(x[:3]).as_matrix() @ Rz, x[3:6], math.exp(x[6])
        self.cache = {}
        self.maps = {}

    def remap(self, rw, rh):
        """For each pixel of a rw x rh straightened frame: where to read the original (bilinear)."""
        if (rw, rh) not in self.maps:
            K, (sw, sh) = self.K, self.size
            v, u = np.mgrid[0:rh, 0:rw].astype(np.float32)
            x = ((u + 0.5) * sw / rw - 0.5 - K["cx"]) / K["f"]
            y = ((v + 0.5) * sh / rh - 0.5 - K["cy"]) / K["f"]
            r2 = x * x + y * y
            d = 1 + K["k1"] * r2 + K["k2"] * r2 * r2
            su, sv = K["cx"] + K["f"] * x * d, K["cy"] + K["f"] * y * d
            x0 = np.clip(np.floor(su).astype(np.int32), 0, sw - 2)
            y0 = np.clip(np.floor(sv).astype(np.int32), 0, sh - 2)
            fx = np.clip(su - x0, 0, 1)[..., None].astype(np.float32)
            fy = np.clip(sv - y0, 0, 1)[..., None].astype(np.float32)
            inside = ((su >= 0) & (su <= sw - 1) & (sv >= 0) & (sv <= sh - 1))[..., None]
            nearest = (np.clip(np.rint(sv), 0, sh - 1).astype(np.int32) * sw
                       + np.clip(np.rint(su), 0, sw - 1).astype(np.int32)).ravel()
            self.maps[(rw, rh)] = (x0, y0, fx, fy, inside, nearest)
        return self.maps[(rw, rh)]

    def frame_at(self, i, rw, rh, fast=False):
        """Frame i straightened to a pinhole camera, at rw x rh (float RGB 0-1).
        fast: one read per pixel (for playback) instead of four blended."""
        from PIL import Image

        im = np.asarray(Image.open(self.path / "solve" / "images" / self.frames[i][0]).convert("RGB"))
        x0, y0, fx, fy, inside, nearest = self.remap(rw, rh)
        if fast:
            out = np.take(im.reshape(-1, 3), nearest, axis=0).reshape(rh, rw, 3)
            return out.astype(np.float32) * (inside / np.float32(255))
        src = im.astype(np.float32) / 255
        top = src[y0, x0] * (1 - fx) + src[y0, x0 + 1] * fx
        bottom = src[y0 + 1, x0] * (1 - fx) + src[y0 + 1, x0 + 1] * fx
        return (top * (1 - fy) + bottom * fy) * inside

    def camera(self, i):
        """Build frame (metres) -> this frame's camera (COLMAP: x right, y down, z forward)."""
        _, Rf, tf = self.frames[i]
        return Rf @ self.Rp, (Rf @ self.shift + tf) / self.scale

    def image(self, i):
        """The frame, undistorted to a pinhole camera with the same f, cx, cy (float RGB 0-1)."""
        if i in self.cache:
            return self.cache[i]
        from PIL import Image
        from scipy.ndimage import map_coordinates

        src = np.asarray(Image.open(self.path / "solve" / "images" / self.frames[i][0]).convert("RGB"),
                         dtype=np.float32) / 255
        h, w, _ = src.shape
        K = self.K
        v, u = np.mgrid[0:h, 0:w].astype(np.float64)
        x, y = (u - K["cx"]) / K["f"], (v - K["cy"]) / K["f"]
        r2 = x * x + y * y
        d = 1 + K["k1"] * r2 + K["k2"] * r2 * r2
        coords = [K["cy"] + K["f"] * y * d, K["cx"] + K["f"] * x * d]
        out = np.stack([map_coordinates(src[..., c], coords, order=1, mode="constant") for c in range(3)], -1)
        if len(self.cache) > 6:
            self.cache.pop(next(iter(self.cache)))
        self.cache[i] = out.astype(np.float32)
        return self.cache[i]


# ─── statistics panel ────────────────────────────────────────────────────────
def fmt_num(v):
    return f"{v:,.0f}" if abs(v) >= 100 else f"{v:.3g}"


def fmt_bytes(n):
    return f"{n / 2**20:.1f} MB" if n >= 2**20 else f"{n / 2**10:.0f} KB"


def stats_rows(st):
    """Rows of (text, color) segments for the corner panel."""
    v, d = FG, DIM
    sx, sy, sz = st["size"]
    unit = f" {st['unit']}" if st["unit"] else ""
    rows = [
        [(f"{st['tris']:,}", v), (" tris  ", d), (f"{st['verts']:,}", v), (" verts", d)],
        [(f"{st['objects']}", v), (" objects  ", d), (f"{st['materials']}", v), (" materials", d)],
        [(f"{fmt_num(sx)} × {fmt_num(sy)} × {fmt_num(sz)}", v), (unit, d)],
    ]
    tex = st["textures"]
    if tex:
        counts = {}
        for w, h in tex:
            counts[f"{w}×{h}"] = counts.get(f"{w}×{h}", 0) + 1
        rows.append([(f"{len(tex)}", v), (" textures  ", d), (fmt_bytes(st["texture_bytes"]), v)])
        sizes = [(f"{n}× " if n > 1 else "", d) for n in counts.values()]
        row = []
        for (prefix, _), size in zip(sizes, counts):
            row += [(prefix, d), (size, v), ("  ", d)]
        rows.append(row[:-1])
    else:
        rows.append([("no textures", d)])
    return rows


def render_panel(rows, cols):
    """ANSI for the panel at the top-left, clipped to the pane width."""
    width = min(max(sum(len(t) for t, _ in r) for r in rows) + 2, cols)
    out = []
    for i, row in enumerate(rows):
        line, used = "", 1
        for text, color in row:
            text = text[: max(0, width - 1 - used)]
            line += f"\x1b[38;2;{color}m{text}"
            used += len(text)
        out.append(f"\x1b[{i + 1};1H\x1b[48;2;{PANEL_BG}m " + line + " " * max(0, width - used) + "\x1b[0m")
    return "".join(out)


# ─── app ─────────────────────────────────────────────────────────────────────
class Viewer:
    def __init__(self, model):
        self.model = Path(model).resolve()
        self.renderer = Renderer()
        self.cam = Camera()
        self.mode = 1
        self.spin = True
        self.wire = False
        self.grid = True
        self.view_i = 0
        self.dirty = True
        self.last_input = 0.0
        self.refined = False
        self.message = ""
        self.stats = None
        self.panel_dirty = True
        self.loaded_mtime = None
        self.export_proc = None
        self.drag = None
        self.visible = True
        self.vis_checked = 0.0
        self.xform = (np.zeros(3), 1.0)  # file coords = viewer coords * radius + center
        self.layout = None  # (cols, image rows, cell w, cell h) of the pane
        self.click = None  # last thing the user clicked, for Claude
        self.click_mark = None  # viewer-space point under the teal ring
        self.claude_mark = None  # viewer-space point under the gold ring
        # <model>.meshview.json (written by model-preview's preview_build.sh): the source
        # .blend's placed shots and the file's unit, for a preview outside the project
        side = Path(str(self.model) + ".meshview.json")
        side = json.loads(side.read_text()) if side.exists() else {}
        self.refs = shots_in(side["refs"]) if side.get("refs") else find_refs(model)
        self.ref_shots = {}
        self.ref = None  # (shot index, frame index) while showing the model through a show camera
        self.ref_style = "outline"
        self.foot_cache = None
        # metres per file unit, for the footage cameras. A .glb in a project with placed shots
        # (found by walking up to observations/place) is that project's Roblox export: studs.
        in_project = bool(self.refs) and not side.get("refs") and not os.environ.get("MESHVIEW_REFS")
        default_unit = STUD_M if in_project and Path(model).suffix.lower() == ".glb" else 1.0
        self.unit_m = float(os.environ.get("MESHVIEW_UNIT_M", side.get("unit_m", default_unit)))
        self.glb = self.model
        if self.model.suffix.lower() == ".blend":
            cache = Path(tempfile.gettempdir()) / "meshview"
            cache.mkdir(exist_ok=True)
            self.glb = cache / (self.model.stem + "-" + __import__("hashlib").md5(str(self.model).encode()).hexdigest()[:8] + ".glb")

    # model file / .blend export
    def source_mtime(self):
        try:
            return self.model.stat().st_mtime
        except FileNotFoundError:
            return None

    def poll_file(self):
        m = self.source_mtime()
        if m is None:
            self.message = "file not found"
            return
        if self.export_proc is not None:
            if self.export_proc.poll() is None:
                return
            ok = self.export_proc.returncode == 0 and self.glb.exists()
            self.export_proc = None
            if not ok:
                self.message = "Blender export failed"
                self.loaded_mtime = self.pending_mtime
                return
            self.load(self.pending_mtime)
            return
        if m == self.loaded_mtime:
            return
        if self.model != self.glb:
            if not Path(BLENDER).exists():
                self.message = "Blender not found for .blend export"
                self.loaded_mtime = m
                return
            self.pending_mtime = m
            self.message = "exporting .blend…"
            self.export_proc = export_blend(self.model, self.glb)
            self.dirty = True
            return
        # let a writer finish: only load once the mtime has settled
        if time.time() - m < 0.3:
            return
        self.load(m)

    def load(self, mtime):
        try:
            parts, ground, stats, xform = load_model(self.glb)
        except Exception as e:  # keep showing the last good model
            self.message = f"load failed: {e}"[:80]
            self.loaded_mtime = mtime
            self.dirty = True
            return
        self.renderer.upload(parts, ground)
        self.xform = xform
        log("loaded", stats["tris"])
        self.stats = stats
        self.panel_dirty = True
        self.loaded_mtime = mtime
        self.message = ""
        self.dirty = True
        self.refined = False

    # input
    def interact(self):
        self.last_input = time.time()
        self.dirty = True
        self.refined = False

    def handle(self, ev):
        step = math.radians(10)
        if ev[0] == "key":
            k = ev[1]
            if k in ("q", "\x03", "esc"):
                return False
            if self.message.endswith(" view"):
                self.message = ""
            if self.ref is not None:  # footage view: arrows (or h j k l) pause and step; space plays
                step = {"left": "[", "h": "[", "right": "]", "l": "]", "up": "{", "k": "{", "down": "}", "j": "}"}
                if k == " ":
                    self.ref_play = not getattr(self, "ref_play", False)
                    self.ref_t = time.time()
                    self.interact()
                    return True
                if k in step:
                    self.ref_play = False
                    return self.ref_key(step[k])
            if self.ref is not None and k == "s":  # the real shot alone, and back
                self.ref_real = not getattr(self, "ref_real", False)
                self.interact()
                return True
            if k in ("r", "[", "]", "{", "}", "o"):
                return self.ref_key(k)
            if self.ref is not None and k in ("h", "j", "k", "l", "H", "J", "K", "L", "left", "right", "up",
                                               "down", "+", "=", "-", "_", "f", "v"):
                self.leave_ref()
            if k in ("h", "left"):
                self.cam.orbit(step, 0); self.spin = False
            elif k in ("l", "right"):
                self.cam.orbit(-step, 0); self.spin = False
            elif k in ("k", "up"):
                self.cam.orbit(0, step); self.spin = False
            elif k in ("j", "down"):
                self.cam.orbit(0, -step); self.spin = False
            elif k in ("H", "J", "K", "L"):
                d = {"H": (-0.1, 0), "L": (0.1, 0), "K": (0, 0.1), "J": (0, -0.1)}[k]
                self.cam.pan(*d)
            elif k in ("+", "="):
                self.cam.zoom(0.85)
            elif k in ("-", "_"):
                self.cam.zoom(1 / 0.85)
            elif k in ("1", "2", "3"):
                self.mode = int(k) - 1
                self.spin = self.mode != 2
            elif k == " ":
                self.spin = not self.spin
            elif k == "z":
                self.wire = not self.wire
            elif k == "g":
                self.grid = not self.grid
            elif k == "f":
                self.cam.reset()
            elif k == "v":
                name, yaw, pitch = VIEWS[self.view_i % len(VIEWS)]
                self.view_i += 1
                self.cam.yaw, self.cam.pitch = yaw, pitch
                self.spin = False
                self.message = f"{name} view"
            else:
                return True
            self.interact()
        elif ev[0] == "mouse":
            _, b, x, y, pressed = ev
            if b in (64, 65):
                self.leave_ref()
                self.cam.zoom(0.9 if b == 64 else 1 / 0.9)
                self.interact()
            elif pressed and not (b & 32):
                self.drag = (b & 3, x, y)
                self.dragged = False
            elif pressed and (b & 32) and self.drag:
                btn, px, py = self.drag
                self.dragged = True
                self.leave_ref()
                dx, dy = x - px, y - py
                if btn == 0 and not (b & 4):  # left drag: orbit, like Blender's MMB
                    self.cam.orbit(-dx * math.radians(2.5), dy * math.radians(4))
                    self.spin = False
                else:  # right/middle drag or shift-drag: pan
                    self.cam.pan(dx * 0.02, -dy * 0.04)
                self.drag = (btn, x, y)
                self.interact()
            elif not pressed:
                if self.drag and self.drag[0] == 0 and not getattr(self, "dragged", True):
                    self.pick_at(x, y)
                self.drag = None
        return True

    # ─── reference footage ──────────────────────────────────────────────────
    def ref_shot(self, i=None):
        i = self.ref[0] if i is None else i
        if i not in self.ref_shots:
            self.ref_shots[i] = RefShot(self.refs[i])
        return self.ref_shots[i]

    def ref_info(self):
        if self.ref is None:
            return None
        shot = self.ref_shot()
        return {"shot": shot.name, "frame": shot.frames[self.ref[1]][0], "index": self.ref[1] + 1,
                "frames": len(shot.frames), "style": self.ref_style, "unit_m": self.unit_m}

    def enter_ref(self, shot, frame=None, play=False):
        n = len(self.ref_shot(shot).frames)
        self.ref = (shot, (n // 2 if frame is None else frame) % n)
        self.ref_play = play
        self.ref_t = time.time()
        self.spin = False
        self.interact()

    def play_step(self, now):
        """Footage view playing: the next frame at the shot's own rate, then on to the next shot."""
        if self.ref is None or not getattr(self, "ref_play", False) or not self.visible:
            return False
        if now - self.ref_t >= 1 / REF_FPS:
            shot, i = self.ref
            if i + 1 < len(self.ref_shot(shot).frames):
                self.ref = (shot, i + 1)
            else:
                self.ref = ((shot + 1) % len(self.refs), 0)
            self.ref_t = now
            self.dirty = True
        return True

    def leave_ref(self):
        if self.ref is not None:
            self.ref = None
            self.message = "left the footage view"

    def ref_key(self, k):
        if not self.refs:
            self.message = "no reference footage for this model"
        elif k == "r":
            if self.ref is None:
                self.enter_ref(0, frame=0, play=True)
            else:
                self.leave_ref()
        elif self.ref is None:
            self.enter_ref(0)
        elif k in "[]":
            self.enter_ref(self.ref[0], self.ref[1] + (1 if k == "]" else -1))
        elif k in "{}":
            self.enter_ref((self.ref[0] + (1 if k == "}" else -1)) % len(self.refs), frame=0)
        elif k == "o":
            styles = ["outline", "wire", "ghost", "model"]
            if self.ref_style not in styles:
                self.ref_style = "footage"  # so the next press starts the cycle again
            self.ref_style = styles[(styles.index(self.ref_style) + 1) % len(styles)]
        self.interact()
        return True

    def ref_view(self, W, H):
        """The footage camera letterboxed into W x H: (rw, rh, x offset, y offset, (eye, view, vp))."""
        shot = self.ref_shot()
        sw, sh = shot.size
        k = min(W / sw, H / sh)
        rw, rh = max(16, int(sw * k)), max(16, int(sh * k))
        f, cx, cy = shot.K["f"] * rw / sw, shot.K["cx"] * rw / sw, shot.K["cy"] * rh / sh
        R, t = shot.camera(self.ref[1])
        center, radius = self.xform
        A = np.identity(4)
        A[:3, :3] *= radius
        A[:3, 3] = center  # viewer -> file
        B = np.array([[1, 0, 0, 0], [0, 0, -1, 0], [0, 1, 0, 0], [0, 0, 0, 1]], dtype=np.float64)  # glTF -> Blender
        S = np.diag([self.unit_m] * 3 + [1.0])  # file units -> metres
        C = np.identity(4)
        C[:3, :3], C[:3, 3] = R, t  # build frame -> COLMAP camera
        view = np.diag([1.0, -1.0, -1.0, 1.0]) @ C @ S @ B @ A  # -> OpenGL camera
        near, far = 0.05, 500.0
        proj = np.array([
            [2 * f / rw, 0, 1 - 2 * cx / rw, 0],
            [0, 2 * f / rh, 2 * cy / rh - 1, 0],
            [0, 0, -(far + near) / (far - near), -2 * far * near / (far - near)],
            [0, 0, -1, 0],
        ])
        eye = (np.linalg.inv(view) @ np.array([0, 0, 0, 1.0]))[:3]
        return rw, rh, (W - rw) // 2, (H - rh) // 2, (eye, view, proj @ view)

    def footage(self, rw, rh):
        fast = getattr(self, "ref_play", False)
        key = (self.ref, rw, rh, fast)
        if not self.foot_cache or self.foot_cache[0] != key:
            self.foot_cache = (key, self.ref_shot().frame_at(self.ref[1], rw, rh, fast))
        return self.foot_cache[1]

    def compose(self, W, H, draw_mode, quality):
        """The pane's picture: the model from the orbit camera, or laid over a footage frame."""
        if self.ref is None:
            return self.renderer.render(self.cam, draw_mode, W, H, self.wire, self.grid, quality, self.markers())
        rw, rh, ox, oy, ov = self.ref_view(W, H)
        real = getattr(self, "ref_real", False) or self.ref_style == "footage"
        if real or self.ref_style == "outline":  # the real frame, alone or with the model's edges
            canvas = np.empty((H, W, 3), dtype=np.float32)
            canvas[:] = BG_BOTTOM
            frame = self.footage(rw, rh)
            if not real:
                lines = self.renderer.outlines(rw, rh, ov).astype(np.float32) / 255
                a = lines[..., 3:4]
                frame = frame * (1 - a) + lines[..., :3] * a
            canvas[oy:oy + rh, ox:ox + rw] = frame
            return (np.clip(canvas, 0, 1) * 255).astype(np.uint8)
        layer = self.renderer.render(self.cam, draw_mode, rw, rh, self.wire, False, True, self.markers(),
                                     override=ov, layer="wire" if self.ref_style == "wire" else "shaded")
        layer = layer.astype(np.float32) / 255
        rgb, a = layer[..., :3], layer[..., 3:4]
        if self.ref_style == "model":
            under = np.array(BG_BOTTOM, dtype=np.float32) * 2
        else:
            under = self.footage(rw, rh)
            if self.ref_style == "ghost":
                a = a * 0.55
        canvas = np.empty((H, W, 3), dtype=np.float32)
        canvas[:] = BG_BOTTOM
        canvas[oy:oy + rh, ox:ox + rw] = under * (1 - a) + rgb * a
        return (np.clip(canvas, 0, 1) * 255).astype(np.uint8)

    # ─── coordinates: viewer space <-> file (glTF, Y up) <-> Blender (Z up) ───
    def to_file(self, p):
        center, radius = self.xform
        return np.asarray(p) * radius + center

    def from_file(self, p):
        center, radius = self.xform
        return (np.asarray(p, dtype=np.float64) - center) / radius

    @staticmethod
    def gltf_to_blender(p):
        return np.array([p[0], -p[2], p[1]])

    @staticmethod
    def blender_to_gltf(p):
        return np.array([p[0], p[2], -p[1]])

    def to_blender(self, p):
        return [round(float(v), 4) for v in self.gltf_to_blender(self.to_file(p))]

    def from_blender(self, p):
        return self.from_file(self.blender_to_gltf(p))

    def camera_info(self):
        return {
            "eye": self.to_blender(self.cam.eye()),
            "target": self.to_blender(self.cam.target),
            "yaw_deg": round(math.degrees(self.cam.yaw), 1),
            "pitch_deg": round(math.degrees(self.cam.pitch), 1),
        }

    # ─── clicking ───────────────────────────────────────────────────────────
    def pick_at(self, x, y):
        """A click (no drag) at cell (x, y), 1-based: record what is under it."""
        self.ref_play = False
        if not self.layout or not self.renderer.parts:
            return
        cols, img_rows, cw, ch = self.layout
        if y > img_rows:
            return
        w, h = max(16, int(cols * cw)), max(16, int(img_rows * ch))
        px, py = min(w - 1, int((x - 0.5) * cw)), min(h - 1, int((y - 0.5) * ch))
        if self.ref is not None:
            rw, rh, ox, oy, ov = self.ref_view(w, h)
            px, py = px - ox, py - oy
            if not (0 <= px < rw and 0 <= py < rh):
                return
            hit = self.renderer.pick(self.cam, rw, rh, px, py, override=ov)
        else:
            hit = self.renderer.pick(self.cam, w, h, px, py)
        self.spin = False
        if hit is None:
            self.click = {"object": None, "camera": self.camera_info(), "time": time.time()}
            self.click_mark = None
            self.message = "nothing there"
        else:
            i, tri, p = hit
            part = self.renderer.parts[i]
            self.click = {
                "object": part.name,
                "triangle": tri,
                "point": self.to_blender(p),
                "camera": self.camera_info(),
                "mode": MODES[self.mode],
                "footage": self.ref_info(),
                "time": time.time(),
            }
            self.click_mark = p
            self.message = f"picked {part.name}"
        self.interact()

    # ─── commands from Claude (meshview ctl) ────────────────────────────────
    def find_parts(self, name):
        name = name.lower()
        exact = [p for p in self.renderer.parts if p.name.lower() == name]
        return exact or [p for p in self.renderer.parts if name in p.name.lower()]

    def frame_parts(self, parts):
        lo = self.from_file(np.min([p.lo for p in parts], axis=0))
        hi = self.from_file(np.max([p.hi for p in parts], axis=0))
        r = max(np.linalg.norm(hi - lo) / 2, 1e-3)
        self.cam.fly_to(target=(lo + hi) / 2, dist=r * 1.2 / math.sin(FOV / 2))

    def command(self, cmd, args):
        kw = dict(a.split("=", 1) for a in args if "=" in a)
        pos = [a for a in args if "=" not in a]
        vec = lambda t: [float(v) for v in t.replace(" ", "").split(",")]
        flag = lambda cur: {"on": True, "off": False}.get(pos[0] if pos else "toggle", not cur)

        if cmd == "help":
            return {"commands": {
                "state": "file, mode, toggles, camera, last click, gold mark, stats",
                "objects": "every object with tris and min/max bounds",
                "click": "what the user last clicked: object, triangle, point, camera then",
                "mode solid|material|render": "switch the look",
                "wire|grid|spin [on|off]": "toggle (no argument flips it)",
                "view front|back|left|right|top|bottom": "fly to a Blender-style view",
                "frame [NAME]": "fly to fit objects whose name contains NAME (no NAME: whole model)",
                "orbit DYAW [DPITCH]": "orbit by degrees",
                "zoom FACTOR": "2 = twice as close",
                "look [from=X,Y,Z] [at=X,Y,Z]": "put the camera at / aim it at points",
                "mark X,Y,Z | mark NAME | mark clear": "gold ring at a point or an object's centre",
                "snapshot PATH [view=…] [frame=NAME] [from=X,Y,Z] [at=X,Y,Z] [mode=…] [size=WxH]": "a render of its own to a PNG; the pane's view never changes",
                "ref list | ref SHOT [FRAME] | ref next|prev [shot] | ref off": "the model through a solved show camera, over that frame",
                "ref style outline|wire|ghost|model|footage | ref unit METRES_PER_UNIT | ref dir PATH": "overlay look (outline: the model's edges only; footage: the frame alone); file units; where the placed shots are",
            }, "coords": "Blender (Z up), file units"}
        if cmd == "state":
            return {
                "file": str(self.model),
                "mode": MODES[self.mode],
                "spin": self.spin, "wire": self.wire, "grid": self.grid,
                "camera": self.camera_info(),
                "click": self.click,
                "mark": self.to_blender(self.claude_mark) if self.claude_mark is not None else None,
                "footage": self.ref_info(),
                "stats": self.stats and {k: v for k, v in self.stats.items() if k != "textures"},
                "coords": "Blender (Z up), file units",
            }
        if cmd == "objects":
            out = []
            for p in self.renderer.parts:
                a, b = self.gltf_to_blender(p.lo), self.gltf_to_blender(p.hi)
                out.append({"name": p.name, "tris": p.tris,
                            "min": [round(float(v), 4) for v in np.minimum(a, b)],
                            "max": [round(float(v), 4) for v in np.maximum(a, b)]})
            return {"objects": out}
        if cmd == "click":
            return {"click": self.click}
        if cmd == "ref":
            return self.ref_command(pos, kw)
        if cmd == "snapshot":
            return self.snapshot(pos, kw)

        # everything below changes the view
        self.interact()
        if cmd == "mode":
            self.mode = MODES.index(pos[0])
            self.spin = self.spin and self.mode != 2
        elif cmd == "wire":
            self.wire = flag(self.wire)
        elif cmd == "grid":
            self.grid = flag(self.grid)
        elif cmd == "spin":
            self.spin = flag(self.spin)
        elif cmd == "view":
            views = {"front": (0, 0), "back": (math.pi, 0), "right": (math.pi / 2, 0),
                     "left": (-math.pi / 2, 0), "top": (0, math.pi / 2), "bottom": (0, -math.pi / 2)}
            yaw, pitch = views[pos[0]]
            self.spin = False
            self.cam.fly_to(yaw=yaw, pitch=pitch)
        elif cmd == "frame":
            self.spin = False
            if pos:
                parts = self.find_parts(" ".join(pos))
                if not parts:
                    return {"error": f"no object matching {' '.join(pos)!r}"}
                self.frame_parts(parts)
                self.message = f"framed {parts[0].name}" + (f" +{len(parts) - 1}" if len(parts) > 1 else "")
            else:
                home = Camera()
                self.cam.fly_to(home.yaw, home.pitch, home.dist, home.target)
        elif cmd == "orbit":
            self.spin = False
            self.cam.fly_to(yaw=self.cam.yaw + math.radians(float(pos[0])),
                            pitch=self.cam.pitch + math.radians(float(pos[1]) if len(pos) > 1 else 0))
        elif cmd == "zoom":
            self.cam.fly_to(dist=self.cam.dist / float(pos[0]))
        elif cmd == "look":
            # look from=x,y,z at=x,y,z  (Blender coordinates)
            self.spin = False
            target = self.from_blender(vec(kw["at"])) if "at" in kw else self.cam.target
            if "from" in kw:
                off = self.from_blender(vec(kw["from"])) - target
                dist = float(np.linalg.norm(off))
                yaw = math.atan2(off[0], off[2])
                pitch = math.asin(max(-1.0, min(1.0, off[1] / max(dist, 1e-9))))
                self.cam.fly_to(yaw, pitch, dist, target)
            else:
                self.cam.fly_to(target=target)
        elif cmd == "mark":
            if not pos or pos[0] == "clear":
                self.claude_mark = None
            elif "," in pos[0]:
                self.claude_mark = self.from_blender(vec(pos[0]))
            else:
                parts = self.find_parts(" ".join(pos))
                if not parts:
                    return {"error": f"no object matching {' '.join(pos)!r}"}
                p = parts[0]
                self.claude_mark = self.from_file((p.lo + p.hi) / 2)
            if len(pos) > 0 and pos[0] != "clear":
                self.message = "look at the gold ring"
        else:
            return {"error": f"unknown command {cmd!r}"}
        return {"ok": True, "camera": self.camera_info()}

    def snapshot(self, pos, kw):
        """A render of its own for Claude: a copy of the pane's view, or a view given here
        (view=, frame=, from= / at=, mode=, size=). The pane's camera and look never change."""
        from PIL import Image

        if not pos:
            return {"error": "snapshot needs a path: snapshot /tmp/x.png [view=top] [frame=NAME] [from=X,Y,Z] [at=X,Y,Z] [mode=solid] [size=WxH]"}
        w, h = (int(v) for v in kw.get("size", "1280x800").split("x"))
        vec = lambda t: [float(v) for v in t.replace(" ", "").split(",")]
        cam = Camera()
        anim = getattr(self.cam, "anim", None)
        src = anim[3] if anim else (self.cam.yaw, self.cam.pitch, self.cam.dist, self.cam.target)
        cam.yaw, cam.pitch, cam.dist, cam.target = src[0], src[1], src[2], np.array(src[3], dtype=np.float64)
        own_view = False
        if "view" in kw:
            views = {"front": (0, 0), "back": (math.pi, 0), "right": (math.pi / 2, 0),
                     "left": (-math.pi / 2, 0), "top": (0, math.pi / 2 - 1e-3), "bottom": (0, -math.pi / 2 + 1e-3)}
            cam.yaw, cam.pitch = views[kw["view"]]
            own_view = True
        if "frame" in kw:
            parts = self.find_parts(kw["frame"])
            if not parts:
                return {"error": f"no object matching {kw['frame']!r}"}
            lo = self.from_file(np.min([p.lo for p in parts], axis=0))
            hi = self.from_file(np.max([p.hi for p in parts], axis=0))
            cam.target = (lo + hi) / 2
            cam.dist = max(np.linalg.norm(hi - lo) / 2, 1e-3) * 1.2 / math.sin(FOV / 2)
            own_view = True
        if "at" in kw:
            cam.target = self.from_blender(vec(kw["at"]))
            own_view = True
        if "from" in kw:
            off = self.from_blender(vec(kw["from"])) - cam.target
            cam.dist = float(np.linalg.norm(off))
            cam.yaw = math.atan2(off[0], off[2])
            cam.pitch = math.asin(max(-1.0, min(1.0, off[1] / max(cam.dist, 1e-9))))
            own_view = True
        mode = MODES.index(kw["mode"]) if "mode" in kw else self.mode
        # render with the copied camera; the pane's own camera and footage view are put back untouched
        saved_cam, saved_ref = self.cam, self.ref
        self.cam = cam
        if own_view:
            self.ref = None  # a view of its own is never the footage camera
        try:
            img = self.compose(w, h, mode, True)
        finally:
            self.cam, self.ref = saved_cam, saved_ref
            self.renderer.size = None  # the pane's next frame gets its own buffers back
            self.dirty = True
        Image.fromarray(img).save(pos[0])
        eye, target = self.to_blender(cam.eye()), self.to_blender(cam.target)
        fmt = lambda v: ",".join(f"{x:g}" for x in v)
        return {"ok": True, "path": pos[0], "mode": MODES[mode],
                "camera": {"eye": eye, "target": target},
                # to show Henri this same view afterwards: meshview ctl <show>
                "show": f"look from={fmt(eye)} at={fmt(target)}"}

    def ref_command(self, pos, kw):
        sub = pos[0] if pos else "list"
        if sub == "dir":
            self.refs, self.ref_shots, self.ref = shots_in(pos[1]), {}, None
            return {"ok": True, "shots": [p.name for p in self.refs]}
        if sub == "unit":
            self.unit_m = float(pos[1])
            self.interact()
            return {"ok": True, "unit_m": self.unit_m}
        if sub == "style":
            self.ref_style = pos[1]
            self.interact()
            return {"ok": True, "footage": self.ref_info()}
        if sub == "off":
            self.leave_ref()
            self.interact()
            return {"ok": True}
        if not self.refs:
            return {"error": "no placed shots found; use: ref dir <observations/place>"}
        if sub == "list":
            return {"shots": [{"shot": p.name, "frames": len(self.ref_shot(i).frames)} for i, p in enumerate(self.refs)],
                    "unit_m": self.unit_m, "current": self.ref_info()}
        if sub in ("next", "prev"):
            d = 1 if sub == "next" else -1
            if self.ref is None:
                self.enter_ref(0)
            elif pos[1:2] == ["shot"]:
                self.enter_ref((self.ref[0] + d) % len(self.refs))
            else:
                self.enter_ref(self.ref[0], self.ref[1] + d)
            return {"ok": True, "footage": self.ref_info()}
        names = [p.name for p in self.refs]
        match = [i for i, n in enumerate(names) if n == sub] or [i for i, n in enumerate(names) if sub in n]
        if not match:
            return {"error": f"no shot matching {sub!r}", "shots": names}
        frame = None
        if len(pos) > 1:
            frames = [f[0] for f in self.ref_shot(match[0]).frames]
            want = pos[1]
            frame = next((j for j, n in enumerate(frames) if Path(n).stem == want.zfill(4) or n == want), None)
            if frame is None:
                return {"error": f"no frame {want!r} in {names[match[0]]}", "first": frames[0], "last": frames[-1]}
        self.enter_ref(match[0], frame)
        return {"ok": True, "footage": self.ref_info()}

    def markers(self):
        m = []
        if self.click_mark is not None:
            m.append((self.click_mark, (0.27, 0.88, 0.80)))
        if self.claude_mark is not None:
            m.append((self.claude_mark, (0.95, 0.75, 0.35)))
        return m

    def serve(self, sock):
        """Answer one meshview ctl request: a JSON line in, a JSON line out."""
        import json

        try:
            conn, _ = sock.accept()
        except BlockingIOError:
            return
        with conn:
            conn.settimeout(2)
            data = b""
            try:
                while not data.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                req = json.loads(data or b"{}")
                reply = self.command(req.get("cmd", "state"), req.get("args", []))
            except Exception as e:
                reply = {"error": f"{type(e).__name__}: {e}"}
            log("ctl", data[:200], "->", str(reply)[:200])
            try:
                conn.sendall((json.dumps(reply) + "\n").encode())
            except OSError:
                pass

    def check_visible(self):
        if not os.environ.get("TMUX_PANE") or time.time() - self.vis_checked < 1.0:
            return
        self.vis_checked = time.time()
        try:
            r = subprocess.run(
                ["tmux", "display", "-p", "-t", os.environ["TMUX_PANE"], "#{window_active}#{session_attached}"],
                capture_output=True, text=True, timeout=1,
            )
            vis = r.stdout.strip().startswith("1") and not r.stdout.strip().endswith("0")
        except Exception:
            vis = True
        if vis != self.visible:
            log("visible", vis, repr(r.stdout) if "r" in dir() else "")
        if vis and not self.visible:
            self.dirty = True
            self.refined = False
        self.visible = vis

    def status_line(self, cols, fps):
        """The bottom row: what is shown on the left, the keys on the right. The keys never
        disappear: when the row is short they go compact first, then the file name goes,
        and only then is the left part cut."""
        mode = MODES[self.mode]
        head = [(f" ◆ {mode}", f"{TEAL};1")]
        name = [(("⟳ " if self.spin else "") + self.model.name, FG)]
        tail = []
        if self.ref is not None:
            r = self.ref_info()
            look = "real shot" if getattr(self, "ref_real", False) else r["style"]
            tail.append((f"{'▶' if getattr(self, 'ref_play', False) else '▣'} {r['shot']} {r['index']}/{r['frames']} {look}", TEAL))
        if self.message:
            tail.append((self.message, GOLD))
        if self.ref is not None:
            keys = ["s real shot  o overlay  space play  ← → frame  ↑ ↓ shot  r back  q quit",
                    "s real  o look  ␣ play  ←→ frame  ↑↓ shot  r back  q"]
        elif self.refs:
            keys = ["1 2 3 mode  space spin  z wire  v view  r footage  q quit",
                    "123 mode  ␣ spin  z wire  v view  r footage  q"]
        else:
            keys = ["1 2 3 mode  space spin  z wire  g grid  v view  f frame  q quit",
                    "123 mode  ␣ spin  z wire  g grid  v view  q"]

        def plain(parts):
            return "  ".join(t for t, _ in parts)

        def width(text):
            import unicodedata
            return sum(2 if unicodedata.east_asian_width(ch) in ("W", "F") else 1 for ch in text)

        def styled(parts):
            return "  ".join(f"\x1b[38;2;{c}m{t}\x1b[22m" for t, c in parts)

        cols -= 2  # a margin: some terminals draw arrows and symbols wider than they report
        for parts in (head + name + tail, head + tail, tail or head):
            for k in keys:
                if width(plain(parts)) + width(k) + 3 <= cols:
                    gap = cols - width(plain(parts)) - width(k) - 1
                    return styled(parts) + " " * gap + f"\x1b[38;2;{DIM}m{k}"
        k = keys[-1]
        room = max(0, cols - width(k) - 3)
        left = plain(tail or head)[:room]
        return f"\x1b[38;2;{TEAL}m{left}" + " " * max(1, cols - width(left) - width(k) - 1) + f"\x1b[38;2;{DIM}m{k}"

    def run(self):
        # nothing may print over the picture: warnings and tracebacks go to a log file
        log_dir = Path.home() / ".cache" / "meshview"
        log_dir.mkdir(parents=True, exist_ok=True)
        sys.stderr = open(log_dir / "meshview.log", "a", buffering=1)
        import warnings
        warnings.simplefilter("default")
        out = sys.stdout
        screen = Screen(out)
        fd_in = sys.stdin.fileno()
        old = termios.tcgetattr(fd_in)
        resized = [True]
        signal.signal(signal.SIGWINCH, lambda *_: resized.__setitem__(0, True))
        if os.environ.get("TMUX_PANE"):
            subprocess.run(["tmux", "set", "-p", "-t", os.environ["TMUX_PANE"], "allow-passthrough", "all"],
                           capture_output=True)
        # control socket for `meshview ctl`; the pane option points Claude at it
        import socket

        sock_dir = Path(tempfile.gettempdir()) / "meshview"
        sock_dir.mkdir(exist_ok=True)
        sock_path = sock_dir / f"{os.getpid()}.sock"
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(sock_path))
        sock.listen(4)
        sock.setblocking(False)
        if os.environ.get("TMUX_PANE"):
            subprocess.run(["tmux", "set", "-p", "-t", os.environ["TMUX_PANE"], "@meshview_sock", str(sock_path)],
                           capture_output=True)
        tty.setcbreak(fd_in)
        screen.write("\x1b[?1049h\x1b[?25l\x1b[2J\x1b[?1002h\x1b[?1006h")
        last = time.time()
        fps = 0.0
        try:
            while True:
                if resized[0]:
                    resized[0] = False
                    cols, rows, cw, ch = screen.size()
                    log("size", cols, rows, cw, ch)
                    self.layout = (cols, max(1, rows - 1), cw, ch)
                    screen.write("\x1b[2J")
                    screen.grid = None
                    status_shown = None
                    self.dirty = True
                    self.refined = False
                self.poll_file()
                self.check_visible()

                now = time.time()
                dt, last = now - last, now
                animating = self.spin and self.mode != 2 and self.visible and self.renderer.parts and self.ref is None
                if animating:
                    self.cam.orbit(SPIN_SPEED * min(dt, 0.1), 0)
                    self.dirty = True
                flying = self.cam.step()
                if flying:  # a camera move from Claude: quick frames until it lands
                    self.interact()
                playing = self.play_step(now)
                idle = now - self.last_input > 0.25
                # render mode: quick frames while moving, one full-quality frame once you stop
                want_refine = self.mode == 2 and idle and not self.refined
                if (self.dirty or want_refine) and self.visible:
                    img_rows = max(1, rows - 1)
                    w = max(16, int(cols * cw))
                    h = max(16, int(img_rows * ch))
                    quality = self.mode != 2 or want_refine
                    # moving frames are capped in size so spinning stays smooth; the
                    # terminal scales the image to the pane either way
                    moving = animating or flying or not idle
                    if moving and w * h > LIVE_PIXELS:
                        k = math.sqrt(LIVE_PIXELS / (w * h))
                        w, h = max(16, int(w * k)), max(16, int(h * k))
                    draw_mode = self.mode if (self.mode != 2 or quality) else 1
                    t0 = time.time()
                    if self.renderer.parts:
                        img = self.compose(w, h, draw_mode, quality)
                        regrid = screen.grid != (cols, img_rows)
                        screen.show(img, cols, img_rows)
                        log("frame", w, h, "regrid", regrid, "panel", self.panel_dirty)
                        if (regrid or self.panel_dirty) and self.stats:
                            screen.write(render_panel(stats_rows(self.stats), cols))
                            self.panel_dirty = False
                    fps = 0.8 * fps + 0.2 / max(time.time() - t0, 1e-3)
                    if want_refine:
                        self.refined = True
                    line = self.status_line(cols, fps)
                    if line != status_shown:
                        screen.status(rows, cols, line)
                        status_shown = line
                    self.dirty = False

                timeout = 1 / 30 if animating or flying or playing else (0.05 if self.mode == 2 and not self.refined else 0.25)
                r, _, _ = select.select([fd_in, sock], [], [], timeout)
                if sock in r:
                    self.serve(sock)
                if fd_in in r:
                    data = os.read(fd_in, 4096)
                    for ev in parse_input(data):
                        if not self.handle(ev):
                            return
        finally:
            sock.close()
            sock_path.unlink(missing_ok=True)
            if os.environ.get("TMUX_PANE"):
                subprocess.run(["tmux", "set", "-pu", "-t", os.environ["TMUX_PANE"], "@meshview_sock"],
                               capture_output=True)
            screen.cleanup()
            screen.write("\x1b[?1002l\x1b[?1006l\x1b[0m\x1b[2J\x1b[?25h\x1b[?1049l")
            termios.tcsetattr(fd_in, termios.TCSADRAIN, old)


def log(*a):
    if os.environ.get("MESHVIEW_LOG"):
        with open(os.environ["MESHVIEW_LOG"], "a") as f:
            print(f"{time.time():.3f}", *a, file=f)


def find_socket(pane=None):
    """The control socket of a meshview pane: the given one, else this window's, else any."""
    if os.environ.get("MESHVIEW_SOCK"):
        return os.environ["MESHVIEW_SOCK"]

    def panes(*scope):
        r = subprocess.run(["tmux", "list-panes", *scope, "-F", "#{pane_id}\t#{@meshview_sock}"],
                           capture_output=True, text=True)
        return [l.split("\t", 1)[1] for l in r.stdout.splitlines() if "\t" in l and l.split("\t", 1)[1]]

    if pane:
        r = subprocess.run(["tmux", "show", "-pqv", "-t", pane, "@meshview_sock"], capture_output=True, text=True)
        return r.stdout.strip() or None
    if os.environ.get("TMUX_PANE"):
        here = panes("-t", os.environ["TMUX_PANE"])
        if here:
            return here[0]
    found = panes("-a")
    return found[0] if found else None


def ctl(args):
    """meshview ctl [--pane %ID] COMMAND [ARGS...]: talk to a running meshview."""
    import json
    import socket

    pane = None
    if args[:1] == ["--pane"]:
        pane, args = args[1], args[2:]
    if not args:
        args = ["state"]
    path = find_socket(pane)
    if not path or not os.path.exists(path):
        print(json.dumps({"error": "no meshview pane is open"}))
        return 1
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
        s.settimeout(10)
        s.connect(path)
        s.sendall((json.dumps({"cmd": args[0], "args": args[1:]}) + "\n").encode())
        data = b""
        while not data.endswith(b"\n"):
            chunk = s.recv(65536)
            if not chunk:
                break
            data += chunk
    reply = json.loads(data or b"{}")
    print(json.dumps(reply, indent=2))
    return 1 if "error" in reply else 0


def main():
    args = sys.argv[1:]
    if not args or args[0] in ("-h", "--help"):
        print(__doc__.strip())
        return 0
    if args[0] == "--split":
        model = Path(args[1]).resolve()
        if not os.environ.get("TMUX"):
            print("meshview --split needs tmux", file=sys.stderr)
            return 1
        me = shutil.which("meshview") or str(Path(__file__).resolve())
        subprocess.run(["tmux", "split-window", "-h", "-c", str(model.parent), me, str(model)])
        return 0
    if args[0] == "ctl":
        return ctl(args[1:])
    if args[0] == "--stats":
        import json

        model = Path(args[1]).resolve()
        glb = model
        if model.suffix.lower() == ".blend":
            glb = Path(tempfile.gettempdir()) / "meshview" / (model.stem + "-stats.glb")
            glb.parent.mkdir(exist_ok=True)
            export_blend(model, glb).wait()
        _, _, stats, _ = load_model(glb)
        stats["textures"] = [f"{w}x{h}" for w, h in stats["textures"]]
        print(json.dumps(stats, indent=2))
        return 0
    if args[0] == "--snapshot":
        out, rest = args[1], args[2:]
        mode = "material"
        if rest[:1] == ["--mode"]:
            mode, rest = rest[1], rest[2:]
        v = Viewer(rest[0])
        if v.model != v.glb:
            p = export_blend(v.model, v.glb)
            p.wait()
        parts, ground, stats, _ = load_model(v.glb)
        v.renderer.upload(parts, ground)
        img = v.renderer.render(v.cam, MODES.index(mode), 1280, 800, False, True, True)
        from PIL import Image

        Image.fromarray(img).save(out)
        print(f"{stats['tris']:,} tris -> {out}")
        return 0
    Viewer(args[0]).run()
    return 0


if __name__ == "__main__":
    sys.exit(main())
