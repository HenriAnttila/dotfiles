#!/usr/bin/env -S uv run --quiet --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["moderngl", "numpy", "trimesh", "pillow", "scipy", "networkx"]
# ///
"""meshview: a 3D model preview that lives in a tmux pane.

    meshview MODEL            view MODEL in this pane
    meshview --split MODEL    open a tmux split beside this pane and view it there
    meshview --stats MODEL    print the model's statistics as JSON
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
from pathlib import Path

import numpy as np

BLENDER = "/Applications/Blender.app/Contents/MacOS/Blender"
MODES = ["solid", "material", "render"]
SPIN_SPEED = math.radians(22)  # radians per second
LIVE_PIXELS = 1_400_000  # max pixels per frame while spinning or dragging
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

    def __init__(self, verts, faces, base, tex, metal, rough):
        self.verts, self.faces = verts, faces
        self.base, self.tex, self.metal, self.rough = base, tex, metal, rough


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
        raw.append((pos, nrm, uv, col, np.asarray(g.faces, dtype=np.uint32), base, tex, metal, rough))
    if not raw:
        raise ValueError("no meshes in file")

    allpos = np.concatenate([r[0] for r in raw])
    lo, hi = allpos.min(0), allpos.max(0)
    center = (lo + hi) / 2
    radius = max(np.linalg.norm(hi - lo) / 2, 1e-9)
    parts = []
    for pos, nrm, uv, col, faces, base, tex, metal, rough in raw:
        p = (pos - center) / radius
        verts = np.hstack([p, nrm, uv, col]).astype("f4")
        parts.append(Part(verts, faces, base, tex, metal, rough))
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
    return parts, ground, stats


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

    def render(self, cam, mode, w, h, wire, grid, quality):
        mgl, c = self.mgl, self.ctx
        samples = self.max_samples if quality else min(4, self.max_samples)
        self.ensure_size(w, h, samples)
        eye, target = cam.eye(), cam.target
        view = look_at(eye, target, np.array([0.0, 1.0, 0.0]))
        proj = perspective(FOV, w / h, 0.02 * cam.dist, 40.0 + cam.dist * 4)
        vp = proj @ view
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
        c.clear(0, 0, 0, 1, depth=1.0)
        c.disable(mgl.DEPTH_TEST)
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
        for p in self.parts:
            self.set(mp, "u_base", tuple(float(x) for x in p.base))
            self.set(mp, "u_metal", p.metal)
            self.set(mp, "u_rough", p.rough)
            self.set(mp, "u_has_tex", p.gltex is not None)
            (p.gltex or self.white).use(location=0)
            p.vao.render()

        if wire:
            c.wireframe = True
            self.set(mp, "u_mode", 3)
            self.set(mp, "u_push", 0.0008)
            self.set(mp, "u_wire", (0.27, 0.88, 0.80, 1.0) if mode == 0 else (0.02, 0.06, 0.07, 1.0))
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

        c.copy_framebuffer(self.out_fbo, self.ms_fbo)
        data = self.out_fbo.read(components=3, alignment=1)
        img = np.frombuffer(data, dtype=np.uint8).reshape(h, w, 3)[::-1]
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
        self.write(f"\x1b[{row};1H\x1b[2K{text}\x1b[0m")

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
            parts, ground, stats = load_model(self.glb)
        except Exception as e:  # keep showing the last good model
            self.message = f"load failed: {e}"[:80]
            self.loaded_mtime = mtime
            self.dirty = True
            return
        self.renderer.upload(parts, ground)
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
                self.cam.zoom(0.9 if b == 64 else 1 / 0.9)
                self.interact()
            elif pressed and not (b & 32):
                self.drag = (b & 3, x, y)
            elif pressed and (b & 32) and self.drag:
                btn, px, py = self.drag
                dx, dy = x - px, y - py
                if btn == 0 and not (b & 4):  # left drag: orbit, like Blender's MMB
                    self.cam.orbit(-dx * math.radians(2.5), dy * math.radians(4))
                    self.spin = False
                else:  # right/middle drag or shift-drag: pan
                    self.cam.pan(dx * 0.02, -dy * 0.04)
                self.drag = (btn, x, y)
                self.interact()
            elif not pressed:
                self.drag = None
        return True

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
        mode = MODES[self.mode]
        bits = [
            f"\x1b[38;2;{TEAL};1m ◆ {mode}\x1b[22m",
            f"\x1b[38;2;{GOLD}m{'⟳ ' if self.spin else ''}\x1b[38;2;{FG}m{self.model.name}",
        ]
        if self.message:
            bits.append(f"\x1b[38;2;{GOLD}m{self.message}")
        left = "  ".join(bits)
        keys = "1 2 3 mode  space spin  z wire  g grid  v view  f frame  q quit"
        visible_len = len(f" ◆ {mode}  {'⟳ ' if self.spin else ''}{self.model.name}") + (
            len(self.message) + 2 if self.message else 0
        )
        if visible_len + len(keys) + 4 <= cols:
            left += " " * (cols - visible_len - len(keys) - 1) + f"\x1b[38;2;{DIM}m{keys}"
        return left

    def run(self):
        out = sys.stdout
        screen = Screen(out)
        fd_in = sys.stdin.fileno()
        old = termios.tcgetattr(fd_in)
        resized = [True]
        signal.signal(signal.SIGWINCH, lambda *_: resized.__setitem__(0, True))
        if os.environ.get("TMUX_PANE"):
            subprocess.run(["tmux", "set", "-p", "-t", os.environ["TMUX_PANE"], "allow-passthrough", "all"],
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
                    screen.write("\x1b[2J")
                    screen.grid = None
                    status_shown = None
                    self.dirty = True
                    self.refined = False
                self.poll_file()
                self.check_visible()

                now = time.time()
                dt, last = now - last, now
                animating = self.spin and self.mode != 2 and self.visible and self.renderer.parts
                if animating:
                    self.cam.orbit(SPIN_SPEED * min(dt, 0.1), 0)
                    self.dirty = True
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
                    moving = animating or not idle
                    if moving and w * h > LIVE_PIXELS:
                        k = math.sqrt(LIVE_PIXELS / (w * h))
                        w, h = max(16, int(w * k)), max(16, int(h * k))
                    draw_mode = self.mode if (self.mode != 2 or quality) else 1
                    t0 = time.time()
                    if self.renderer.parts:
                        img = self.renderer.render(self.cam, draw_mode, w, h, self.wire, self.grid, quality)
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

                timeout = 1 / 30 if animating else (0.05 if self.mode == 2 and not self.refined else 0.25)
                r, _, _ = select.select([fd_in], [], [], timeout)
                if r:
                    data = os.read(fd_in, 4096)
                    for ev in parse_input(data):
                        if not self.handle(ev):
                            return
        finally:
            screen.cleanup()
            screen.write("\x1b[?1002l\x1b[?1006l\x1b[0m\x1b[2J\x1b[?25h\x1b[?1049l")
            termios.tcsetattr(fd_in, termios.TCSADRAIN, old)


def log(*a):
    if os.environ.get("MESHVIEW_LOG"):
        with open(os.environ["MESHVIEW_LOG"], "a") as f:
            print(f"{time.time():.3f}", *a, file=f)


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
    if args[0] == "--stats":
        import json

        model = Path(args[1]).resolve()
        glb = model
        if model.suffix.lower() == ".blend":
            glb = Path(tempfile.gettempdir()) / "meshview" / (model.stem + "-stats.glb")
            glb.parent.mkdir(exist_ok=True)
            export_blend(model, glb).wait()
        _, _, stats = load_model(glb)
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
        parts, ground, stats = load_model(v.glb)
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
