// The codegraph page. It draws the project once, keeps every node where it was
// last time, and lights up one change on top: the uncommitted work or any
// commit. Links stay hidden until asked for, since a few modules (the enums,
// React, Janitor) are required by dozens of others and would bury the rest.
//
// The page follows the current change on its own: the uncommitted work while
// there is any, the newest commit when the tree is clean. Picking an older
// change stops that until you step back to the newest one.

const WORKTREE = "worktree";
const STATUSES = ["A", "M", "D", "R"];

const $ = (id) => document.getElementById(id);
const css = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();
const esc = (s) => String(s).replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[c]);
const api = async (path, init) => {
  const response = await fetch(path, init);
  if (!response.ok) throw new Error(`${path}: ${response.status}`);
  return response;
};
const debounce = (fn, ms) => {
  let t;
  return (...args) => {
    clearTimeout(t);
    t = setTimeout(() => fn(...args), ms);
  };
};

const state = {
  graph: null,
  commits: [],
  dirty: false,
  exhausted: false,
  follow: true,
  ref: null,
  change: null,
  selected: null,
  file: null,
  structure: null,
  explanation: null,
  links: "selected",
};

let cy;
let changeToken = 0;

// ---------------------------------------------------------------- graph

function styles() {
  const c = Object.fromEntries(
    ["bg", "surface", "raised", "line", "text", "muted", "accent", "added", "modified", "deleted", "renamed", "require", "starts", "remote"].map((n) => [n, css(`--${n}`)]),
  );
  const status = { A: c.added, M: c.modified, D: c.deleted, R: c.renamed };
  const mono = css("--mono");
  return [
    {
      selector: "node",
      style: {
        label: "data(display)",
        "font-family": mono,
        "font-size": 14,
        color: c.text,
        "text-valign": "center",
        "text-halign": "center",
        shape: "round-rectangle",
        width: "data(w)",
        height: NODE_H,
        "background-color": c.raised,
        "border-width": 1,
        "border-color": c.line,
      },
    },
    {
      selector: "node:parent",
      style: {
        "text-valign": "top",
        "text-halign": "center",
        "text-margin-y": -4,
        color: c.muted,
        "background-color": c.surface,
        "background-opacity": 0.6,
        padding: 14,
      },
    },
    { selector: "node.root", style: { "font-size": 16, "font-weight": "bold", color: c.text, "background-opacity": 0.2 } },
    { selector: "node.external", style: { color: c.muted, "border-style": "dashed" } },
    { selector: "node.dim", style: { opacity: 0.4 } },
    { selector: "node.contains", style: { "border-color": c.accent, color: c.text } },
    ...STATUSES.map((s) => ({ selector: `node.${s}`, style: { "border-color": status[s], "border-width": 2.5, opacity: 1 } })),
    ...STATUSES.map((s) => ({ selector: `node.${s}:childless`, style: { "background-color": status[s], "background-opacity": 0.22 } })),
    { selector: "node.match", style: { "underlay-color": c.accent, "underlay-opacity": 0.3, "underlay-padding": 4, opacity: 1 } },
    { selector: "node.neighbor", style: { "underlay-color": c.accent, "underlay-opacity": 0.18, "underlay-padding": 3, opacity: 1 } },
    { selector: "node:selected", style: { "underlay-color": c.accent, "underlay-opacity": 0.45, "underlay-padding": 5, opacity: 1 } },
    {
      selector: "edge",
      style: {
        visibility: "hidden",
        width: 1.2,
        "curve-style": "bezier",
        "target-arrow-shape": "triangle",
        "arrow-scale": 0.8,
        "line-color": c.require,
        "target-arrow-color": c.require,
      },
    },
    { selector: "edge.shown", style: { visibility: "visible" } },
    { selector: "edge.hot", style: { width: 2 } },
    { selector: "edge.starts", style: { "line-color": c.starts, "target-arrow-color": c.starts, "line-style": "dotted" } },
    {
      selector: "edge.remote",
      style: {
        "line-color": c.remote,
        "target-arrow-color": c.remote,
        "line-style": "dashed",
        label: "data(label)",
        "font-family": mono,
        "font-size": 12,
        color: c.remote,
        "text-rotation": "autorotate",
        "text-background-color": c.bg,
        "text-background-opacity": 1,
        "text-background-padding": 2,
      },
    },
  ];
}

// Parents before children, so a new node's folder already exists when it is added.
function elements(graph) {
  const nodes = [...graph.nodes].sort((a, b) => a.id.split("/").length - b.id.split("/").length);
  return [
    ...nodes.map((n) => ({
      group: "nodes",
      data: { ...n, display: n.label, w: Math.max(44, n.label.length * 8.6 + 22) },
      classes: [n.kind, n.external && "external", !n.parent && "root"].filter(Boolean).join(" "),
    })),
    ...graph.edges.map((e) => ({ group: "edges", data: e, classes: e.kind })),
  ];
}

const leaves = () => cy.nodes(":childless");

// Bumped whenever node sizes change, so a layout saved for the old sizes is
// laid out again instead of left overlapping.
const LAYOUT_VERSION = 3;

const savePositions = debounce(() => {
  const positions = {};
  leaves().forEach((n) => {
    positions[n.id()] = n.position();
  });
  api("/api/layout", { method: "PUT", body: JSON.stringify({ version: LAYOUT_VERSION, positions }) });
}, 400);

// The map is the folder tree, laid out the same way every time. A folder lists
// its own modules in name order, top to bottom in columns, and packs its
// subfolders below them in rows, also in name order. Links play no part: they
// are hidden most of the time, and a layout pulled around by them moves
// whenever a require changes.
const NODE_H = 28;
const GAP = 12;
const PAD = 14;
const LABEL = 22;

function packLayout() {
  const positions = {};
  const byName = (a, b) => a.data("label").localeCompare(b.data("label"));

  const grid = (nodes) => {
    if (!nodes.length) return { w: 0, h: 0, put() {} };
    const colW = Math.max(...nodes.map((n) => n.data("w")));
    const cols = Math.max(1, Math.min(nodes.length, Math.round(Math.sqrt((nodes.length * (NODE_H + GAP) * 2) / colW))));
    const rows = Math.ceil(nodes.length / cols);
    return {
      w: cols * colW + (cols - 1) * GAP,
      h: rows * NODE_H + (rows - 1) * GAP,
      put(x, y) {
        nodes.forEach((n, i) => {
          const col = Math.floor(i / rows);
          const row = i % rows;
          positions[n.id()] = { x: x + col * (colW + GAP) + n.data("w") / 2, y: y + row * (NODE_H + GAP) + NODE_H / 2 };
        });
      },
    };
  };

  // Rows aim for the given width-to-height shape: roughly square inside
  // folders, the graph area's own shape for the services at the top.
  const shelves = (boxes, minW, aspect) => {
    if (!boxes.length) return { w: 0, h: 0, put() {} };
    const area = boxes.reduce((sum, b) => sum + b.w * b.h, 0);
    const maxW = Math.max(minW, Math.sqrt(area * aspect), ...boxes.map((b) => b.w));
    const rows = [[]];
    let rowW = 0;
    for (const box of boxes) {
      if (rows.at(-1).length && rowW + GAP + box.w > maxW) {
        rows.push([]);
        rowW = 0;
      }
      rowW += (rows.at(-1).length ? GAP : 0) + box.w;
      rows.at(-1).push(box);
    }
    const heights = rows.map((row) => Math.max(...row.map((b) => b.h)));
    const widths = rows.map((row) => row.reduce((sum, b) => sum + b.w, 0) + (row.length - 1) * GAP);
    return {
      w: Math.max(...widths),
      h: heights.reduce((sum, h) => sum + h, 0) + (rows.length - 1) * GAP * 2,
      put(x, y) {
        rows.forEach((row, r) => {
          let at = x;
          for (const box of row) {
            box.put(at, y);
            at += box.w + GAP;
          }
          y += heights[r] + GAP * 2;
        });
      },
    };
  };

  const arrange = (nodes, aspect = 2.25) => {
    const own = grid(nodes.filter((n) => n.isChildless()));
    const folders = shelves(nodes.filter((n) => n.isParent()).map(measure), own.w, aspect);
    const between = own.h && folders.h ? GAP * 2 : 0;
    return {
      w: Math.max(own.w, folders.w),
      h: own.h + between + folders.h,
      put(x, y) {
        own.put(x, y);
        folders.put(x, y + own.h + between);
      },
    };
  };

  // A folder's box is its contents plus cytoscape's padding, with room above for its label.
  const measure = (folder) => {
    const inside = arrange(folder.children().sort(byName).toArray());
    return {
      w: inside.w + PAD * 2,
      h: inside.h + PAD * 2 + LABEL,
      put: (x, y) => inside.put(x + PAD, y + LABEL + PAD),
    };
  };

  arrange(cy.nodes().orphans().sort(byName).toArray(), Math.max(1, cy.width() / Math.max(1, cy.height()))).put(0, 0);
  return positions;
}

function relayout() {
  const positions = packLayout();
  leaves().positions((n) => positions[n.id()]);
}

// A node without a saved position starts next to its saved siblings.
function nearSiblings(node, placed) {
  const siblings = node.parent().children(":childless").filter((s) => placed.has(s.id()));
  if (siblings.empty()) return { x: Math.random() * 40, y: Math.random() * 40 };
  const box = siblings.boundingBox();
  return { x: box.x1 + node.data("w") / 2, y: box.y2 + GAP + NODE_H / 2 };
}

function place(saved) {
  const placed = new Set(Object.keys(saved));
  const missing = leaves().filter((n) => !placed.has(n.id()));
  if (missing.length === leaves().length) {
    relayout();
    savePositions();
    return;
  }
  leaves().forEach((n) => {
    if (placed.has(n.id())) n.position(saved[n.id()]);
  });
  if (missing.empty()) return;
  missing.forEach((n) => {
    n.position(nearSiblings(n, placed));
    placed.add(n.id());
  });
  savePositions();
}

// The whole map when it can be read at that size; otherwise as close as it
// takes for labels to be readable, centred on what the change touched (or on
// the middle of the map when it touched nothing in it). Fit always shows it all.
const READABLE_ZOOM = 0.8;

function focusChange(animate = true) {
  cy.fit(undefined, 30);
  if (cy.zoom() >= READABLE_ZOOM) return;
  const changed = cy.nodes(".A, .M, .D, .R");
  const target = changed.nonempty() ? changed : cy.nodes();
  const view = { zoom: READABLE_ZOOM, center: { eles: target } };
  if (animate) cy.animate({ ...view, duration: 300 });
  else {
    cy.zoom(READABLE_ZOOM);
    cy.center(target);
  }
}

async function reloadGraph() {
  const graph = await (await api("/api/graph")).json();
  state.graph = graph;
  const ids = new Set(graph.nodes.map((n) => n.id));
  const placed = new Set(leaves().map((n) => n.id()));
  const before = new Set(cy.nodes().map((n) => n.id()));
  const next = elements(graph);
  cy.batch(() => {
    cy.edges().remove();
    cy.nodes()
      .filter((n) => !ids.has(n.id()))
      .remove();
    cy.add(next.filter((e) => e.group === "nodes" && !before.has(e.data.id)));
    for (const n of graph.nodes) {
      const node = cy.getElementById(n.id);
      if ((node.data("parent") ?? null) !== (n.parent ?? null)) node.move({ parent: n.parent ?? null });
    }
    cy.add(next.filter((e) => e.group === "edges"));
    for (const n of graph.nodes) cy.getElementById(n.id).data({ file: n.file ?? null, doc: n.doc ?? null, purpose: n.purpose ?? null });
  });
  askForPurposes();
  const fresh = leaves().filter((n) => !placed.has(n.id()));
  if (fresh.nonempty()) {
    fresh.forEach((n) => n.position(nearSiblings(n, placed)));
    savePositions();
  }
  if (state.selected && cy.getElementById(state.selected).empty()) state.selected = null;
  applyChange();
  renderPanel();
}

// ---------------------------------------------------------------- change

const nodeFor = (f) => state.graph.files[f.path] ?? (f.oldPath ? state.graph.files[f.oldPath] : undefined) ?? null;
const fileFor = (id) => state.change?.files.find((f) => nodeFor(f) === id) ?? null;
const currentRef = () => (state.dirty ? WORKTREE : state.commits[0]?.hash ?? WORKTREE);
const refs = () => [...(state.dirty ? [WORKTREE] : []), ...state.commits.map((c) => c.hash)];

function applyChange() {
  const files = state.change?.files ?? [];
  cy.batch(() => {
    cy.nodes().removeClass("A M D R dim contains");
    cy.nodes().forEach((n) => n.data("display", n.data("label")));
    const inside = new Map();
    let touched = 0;
    for (const f of files) {
      const id = nodeFor(f);
      if (!id) continue;
      const node = cy.getElementById(id);
      if (node.empty()) continue;
      touched++;
      node.addClass(f.status);
      node.ancestors().forEach((a) => inside.set(a.id(), (inside.get(a.id()) ?? 0) + 1));
    }
    for (const [id, count] of inside) {
      const folder = cy.getElementById(id);
      folder.addClass("contains");
      folder.data("display", `${folder.data("label")} · ${count}`);
    }
    if (touched) leaves().not(".A, .M, .D, .R").addClass("dim");
  });
  showLinks();
}

async function selectChange(ref, { fromEvent = false } = {}) {
  const token = ++changeToken;
  state.ref = ref;
  const data = await (await api(`/api/change?ref=${encodeURIComponent(ref)}`)).json();
  if (token !== changeToken) return;
  const same = state.change?.ref === data.ref;
  state.change = data;
  state.ref = data.ref;
  state.follow = state.ref === currentRef();
  if (!same) {
    state.structure = null;
    state.explanation = null;
  }
  if (state.file && !state.change.files.some((f) => f.path === state.file.path)) state.file = null;
  applyChange();
  if (!same) focusChange();
  renderHeader();
  renderPanel();
  if (!$("commits").hidden) renderCommits();
  loadDescription({ fromEvent });
}

// ---------------------------------------------------------------- descriptions
//
// The structure of a change is worked out by the server; the description is
// written by explain.ts. A change with no description gets one asked for: a
// commit after it has been on screen for a moment, so stepping through history
// doesn't start one per commit; the uncommitted work right away when the page
// opens, and once edits have paused for a while after that.

let explainTimer = null;

async function loadDescription({ fromEvent = false, structure = true } = {}) {
  const ref = state.change?.ref;
  if (!ref) return;
  const q = `ref=${encodeURIComponent(ref)}`;
  const [shape, explanation] = await Promise.all([
    structure ? api(`/api/structure?${q}`).then((r) => r.json()) : state.structure,
    api(`/api/explanation?${q}`).then((r) => r.json()),
  ]);
  if (state.change?.ref !== ref) return;
  state.structure = shape;
  state.explanation = explanation;
  renderDescription();
  askForDescription(ref, fromEvent);
}

function askForDescription(ref, fromEvent) {
  clearTimeout(explainTimer);
  const e = state.explanation;
  const missing = ref === WORKTREE ? e.pending.length > 0 : !e.summary;
  if (!missing || e.running) return;
  const delay = ref !== WORKTREE ? 1500 : fromEvent ? 20000 : 0;
  explainTimer = setTimeout(async () => {
    if (state.change?.ref !== ref) return;
    const { started } = await (await api(`/api/explain?ref=${encodeURIComponent(ref)}`, { method: "POST" })).json();
    if (started && state.change?.ref === ref) {
      state.explanation = { ...state.explanation, running: true };
      renderDescription();
    }
  }, delay);
}

// The summary view is all description, so it is drawn again; a module or file
// view only has its note replaced, which leaves its diff alone.
function renderDescription() {
  const note = $("note");
  if (note) note.innerHTML = noteHtml(note.dataset.path);
  else if (!state.selected && !state.file) renderPanel();
}

let loading = null;
function loadMore() {
  if (state.exhausted) return Promise.resolve();
  loading ??= api(`/api/commits?skip=${state.commits.length}&limit=50`)
    .then((r) => r.json())
    .then((data) => {
      state.commits.push(...data.commits);
      state.dirty = data.dirty;
      if (data.commits.length < 50) state.exhausted = true;
    })
    .finally(() => {
      loading = null;
    });
  return loading;
}

async function refreshGit() {
  const limit = Math.max(50, state.commits.length);
  const data = await (await api(`/api/commits?skip=0&limit=${limit}`)).json();
  state.commits = data.commits;
  state.dirty = data.dirty;
  state.exhausted = data.commits.length < limit;
  if (state.follow || state.ref === WORKTREE) await selectChange(state.follow ? currentRef() : WORKTREE, { fromEvent: true });
  else renderHeader();
  if (!$("commits").hidden) renderCommits();
}

async function step(direction) {
  let list = refs();
  const at = list.indexOf(state.ref);
  if (direction > 0 && at >= list.length - 1) {
    await loadMore();
    list = refs();
  }
  const next = list[at + direction];
  if (next) selectChange(next);
}

// ---------------------------------------------------------------- links

function showLinks() {
  cy.batch(() => {
    cy.edges().removeClass("shown hot");
    cy.nodes().removeClass("neighbor");
    let shown = cy.collection();
    if (state.links === "all") shown = cy.edges();
    if (state.links === "changed") {
      const changed = cy.nodes(".A, .M, .D, .R");
      shown = changed.edgesWith(changed);
    }
    const selected = state.selected ? cy.getElementById(state.selected) : cy.collection();
    if (selected.nonempty()) {
      const members = selected.union(selected.descendants());
      const own = members.connectedEdges();
      own.addClass("hot");
      own.connectedNodes().difference(members).addClass("neighbor");
      shown = shown.union(own);
    }
    shown.addClass("shown");
  });
}

// ---------------------------------------------------------------- header

const ago = (date) => {
  const seconds = (new Date(date).getTime() - Date.now()) / 1000;
  const rtf = new Intl.RelativeTimeFormat("en", { numeric: "auto" });
  for (const [unit, size] of [["year", 31536000], ["month", 2592000], ["week", 604800], ["day", 86400], ["hour", 3600], ["minute", 60]]) {
    if (Math.abs(seconds) >= size) return rtf.format(Math.round(seconds / size), unit);
  }
  return "just now";
};

const counts = (a, d) => `<span class="counts"><span class="plus">+${a}</span> <span class="minus">−${d}</span></span>`;
const totals = (files) =>
  counts(
    files.reduce((n, f) => n + f.additions, 0),
    files.reduce((n, f) => n + f.deletions, 0),
  );

function renderHeader() {
  const c = state.change;
  const title = $("change-title");
  const meta = $("change-meta");
  if (!c) {
    title.textContent = "Loading…";
    meta.textContent = "";
  } else if (c.ref === WORKTREE) {
    title.textContent = "Uncommitted changes";
    meta.innerHTML = c.files.length ? `${c.files.length} files &nbsp;${totals(c.files)}` : "clean";
  } else {
    title.textContent = c.commit.subject;
    meta.innerHTML = `${esc(c.commit.short)} · ${ago(c.commit.date)} &nbsp;${counts(c.commit.additions, c.commit.deletions)}`;
  }
  const list = refs();
  const at = list.indexOf(state.ref);
  $("older").disabled = at < 0 || (at >= list.length - 1 && state.exhausted);
  $("newer").disabled = at <= 0;
}

function renderCommits() {
  const rows = [];
  if (state.dirty) {
    rows.push(
      `<button class="commit worktree ${state.ref === WORKTREE ? "current" : ""}" data-ref="${WORKTREE}"><span class="hash">●</span><span class="subject">Uncommitted changes</span><span class="when">now</span></button>`,
    );
  }
  for (const c of state.commits) {
    rows.push(
      `<button class="commit ${state.ref === c.hash ? "current" : ""}" data-ref="${c.hash}"><span class="hash">${esc(c.short)}</span><span class="subject">${c.explained ? `<i class="described" title="Has a description"></i>` : ""}${esc(c.subject)}</span><span class="when">${ago(c.date)}</span></button>`,
    );
  }
  rows.push(`<div class="more">${state.exhausted ? "That's every commit." : "Scroll for older commits"}</div>`);
  $("commits").innerHTML = rows.join("");
}

function toggleCommits(open = $("commits").hidden) {
  const box = $("commits");
  box.hidden = !open;
  if (!open) return;
  renderCommits();
  box.querySelector(".current")?.scrollIntoView({ block: "nearest" });
}

// ---------------------------------------------------------------- panel

const instancePath = (id) => id.split("/").join(".");
const split = (path) => {
  const at = path.lastIndexOf("/");
  return at < 0 ? ["", path] : [path.slice(0, at), path.slice(at + 1)];
};

function fileRow(f) {
  const id = nodeFor(f);
  const node = id ? cy.getElementById(id) : null;
  const [dir, base] = node ? [instancePath(node.parent().id() || ""), node.data("label")] : split(f.path);
  const counted = f.binary ? `<span class="counts">binary</span>` : counts(f.additions, f.deletions);
  return `<li data-path="${esc(f.path)}"><span class="status ${f.status}">${f.status}</span><span class="name">${esc(base)} <span class="where">${esc(dir)}</span></span>${counted}</li>`;
}

function renderSummary(body) {
  const c = state.change;
  if (!c) {
    body.innerHTML = "";
    return;
  }
  const head =
    c.ref === WORKTREE
      ? `<h2>Uncommitted changes</h2><div class="meta">${c.files.length} files changed against HEAD</div>`
      : `<h2>${esc(c.commit.subject)}</h2><div class="meta">${esc(c.commit.short)} · ${esc(c.commit.author)} · ${new Date(c.commit.date).toLocaleString()}</div>`;
  const e = state.explanation;
  let html = head;
  if (e?.summary) html += `<p class="summary">${esc(e.summary)}</p>${byLine(e)}`;
  else if (e?.running) html += `<p class="status-line">Describing this change…</p>`;
  if (!c.files.length) html += `<p class="empty">${c.ref === WORKTREE ? "Nothing uncommitted." : "This commit changed no files."}</p>`;
  html += structureHtml(state.structure);

  // Files under the feature they were grouped into; whatever no feature claims
  // (not described yet, or left out by the description) under where it lives.
  const grouped = new Set();
  for (const feature of e?.features ?? []) {
    const files = c.files.filter((f) => feature.files.includes(f.path) && !grouped.has(f.path));
    if (!files.length) continue;
    files.forEach((f) => grouped.add(f.path));
    html += `<section class="feature"><h3>${esc(feature.name)}</h3><p class="description">${esc(feature.description)}</p><ul class="files">${files.map(fileRow).join("")}</ul></section>`;
  }
  const rest = c.files.filter((f) => !grouped.has(f.path));
  const label = grouped.size ? (c.ref === WORKTREE && e?.running ? "Being described" : "Not described yet") : null;
  const inside = rest.filter((f) => nodeFor(f) && cy.getElementById(nodeFor(f)).nonempty());
  const outside = rest.filter((f) => !inside.includes(f));
  if (label && rest.length) html += `<h3>${label}</h3><ul class="files">${rest.map(fileRow).join("")}</ul>`;
  else {
    if (inside.length) html += `<h3>In the game</h3><ul class="files">${inside.map(fileRow).join("")}</ul>`;
    if (outside.length) html += `<h3>Outside the game tree</h3><ul class="files">${outside.map(fileRow).join("")}</ul>`;
  }
  body.innerHTML = html;
}

const byLine = (e) =>
  e.by ? `<p class="by">${e.by === "session" ? "Written by the session that made it" : "Written from the diff"}</p>` : "";

const VERB = { require: "requires", starts: "starts", remote: "fires" };

function structureHtml(s) {
  if (!s) return "";
  const label = (id) => esc(id.split("/").at(-1));
  const rows = [
    ...s.modules.added.map((m) => ({ sign: "+", node: m.id, text: `new module <b>${label(m.id)}</b> <span class="where">${esc(instancePath(m.parent ?? ""))}</span>` })),
    ...s.modules.removed.map((m) => ({ sign: "−", text: `removed module <b>${label(m.id)}</b> <span class="where">${esc(instancePath(m.parent ?? ""))}</span>` })),
    ...s.links.added.map((l) => ({ sign: "+", node: l.source, text: `${label(l.source)} <span class="verb">${VERB[l.kind]}</span> ${label(l.target)}${l.label ? ` <span class="where">${esc(l.label)}</span>` : ""}` })),
    ...s.links.removed.map((l) => ({ sign: "−", node: l.source, text: `${label(l.source)} <span class="verb">no longer ${VERB[l.kind]}</span> ${label(l.target)}${l.label ? ` <span class="where">${esc(l.label)}</span>` : ""}` })),
  ];
  if (!rows.length) return `<h3>Structure</h3><p class="meta">No modules or links added or removed.</p>`;
  const items = rows
    .map((r) => `<li class="${r.sign === "+" ? "added" : "removed"}" ${r.node && cy.getElementById(r.node).nonempty() ? `data-node="${esc(r.node)}"` : ""}><span class="sign">${r.sign}</span><span>${r.text}</span></li>`)
    .join("");
  return `<h3>Structure</h3><ul class="structure">${items}</ul>`;
}

// What changed in one file and why, from the description of the change it's in.
function noteHtml(path) {
  const e = state.explanation;
  const note = e?.files?.[path];
  const feature = e?.features?.find((f) => f.files.includes(path));
  if (note) {
    return `${feature ? `<p class="by">Part of <b>${esc(feature.name)}</b></p>` : ""}
      <dl class="note"><dt>What</dt><dd>${esc(note.what)}</dd><dt>Why</dt><dd>${esc(note.why)}</dd></dl>`;
  }
  if (e?.running) return `<p class="status-line">Describing this change…</p>`;
  return "";
}

function refList(title, items) {
  if (!items.length) return "";
  const rows = items
    .map(({ node, note }) => `<li data-node="${esc(node.id())}"><span class="name">${esc(node.data("label"))} <span class="where">${esc(instancePath(node.parent().id() || ""))}</span></span><span class="meta">${esc(note ?? "")}</span></li>`)
    .join("");
  return `<h3>${title} (${items.length})</h3><ul class="refs">${rows}</ul>`;
}

// ---------------------------------------------------------------- what a module does
//
// From the comment the file opens with when it has one, otherwise the sentence
// explain.ts wrote from its code. Modules with neither get one asked for.

const paragraphs = (text) => text.split(/\n\s*\n/);
const oneLine = (text) => text.replace(/\s*\n\s*/g, " ").trim();

function about(d) {
  if (d.doc) return { text: oneLine(paragraphs(d.doc)[0]), more: paragraphs(d.doc).slice(1).join("\n\n"), by: "comment" };
  if (d.purpose) return { text: d.purpose, more: "", by: "ai" };
  return null;
}

function aboutHtml(d) {
  const a = about(d);
  if (!a) return d.kind === "script" && !d.external ? `<p class="by about-missing">No description yet.</p>` : "";
  return `<div class="about"><p>${esc(a.text)}</p>
    ${a.more ? `<details><summary>More from the file's comment</summary><pre>${esc(a.more)}</pre></details>` : ""}
    ${a.by === "ai" ? `<p class="by">Written by AI from the code</p>` : ""}</div>`;
}

function askForPurposes() {
  const missing = cy.nodes().some((n) => n.data("kind") === "script" && !n.data("external") && !n.data("doc") && !n.data("purpose"));
  if (missing) api("/api/purposes", { method: "POST" }).catch(() => {});
}

function showTip(node) {
  const tip = $("tip");
  const a = about(node.data());
  if (!a) return hideTip();
  const first = a.text.match(/^.*?[.!?](\s|$)/)?.[0] ?? a.text;
  tip.innerHTML = `<b>${esc(node.data("label"))}</b><span>${esc(first.length > 220 ? `${first.slice(0, 217)}…` : first)}</span>`;
  const box = node.renderedBoundingBox();
  const area = $("graph").getBoundingClientRect();
  tip.hidden = false;
  const left = Math.min(box.x1, area.width - tip.offsetWidth - 8);
  const below = box.y2 + 8;
  tip.style.left = `${Math.max(8, left)}px`;
  tip.style.top = `${below + tip.offsetHeight > area.height ? box.y1 - tip.offsetHeight - 8 : below}px`;
}

function hideTip() {
  $("tip").hidden = true;
}

function backLabel() {
  if (!state.change) return "Back";
  return state.change.ref === WORKTREE ? "Uncommitted changes" : state.change.commit.short;
}

function renderNode(body, node) {
  const d = node.data();
  const f = fileFor(node.id());
  let html = `<button class="back" data-back>← ${esc(backLabel())}</button>
    <h2>${esc(d.label)}</h2>
    <div class="meta">${esc(d.className)} · ${esc(instancePath(d.id))}</div>
    ${d.file ? `<div class="meta">${esc(d.file)}</div>` : ""}
    ${aboutHtml(d)}`;

  if (f) {
    html += `<h3>In this change &nbsp;<span class="status ${f.status}">${f.status}</span> ${f.binary ? "" : counts(f.additions, f.deletions)}</h3>
      <div id="note" data-path="${esc(f.path)}">${noteHtml(f.path)}</div><div class="diff" id="diff"></div>`;
  }

  const changedInside = node.descendants(".A, .M, .D, .R");
  if (changedInside.nonempty()) {
    const rows = changedInside.map((n) => fileRow(fileFor(n.id()))).join("");
    html += `<h3>Changed inside (${changedInside.length})</h3><ul class="files">${rows}</ul>`;
  } else if (!f) {
    html += `<p class="meta">Not touched by this change.</p>`;
  }

  const out = node.outgoers("edge");
  const into = node.incomers("edge");
  html += refList("Requires", out.filter(".require").map((e) => ({ node: e.target() })));
  html += refList("Required by", into.filter(".require").map((e) => ({ node: e.source() })));
  html += refList("Starts", out.filter(".starts").map((e) => ({ node: e.target() })));
  html += refList("Started by", into.filter(".starts").map((e) => ({ node: e.source() })));
  html += refList("Fires remotes to", out.filter(".remote").map((e) => ({ node: e.target(), note: e.data("label") })));
  html += refList("Hears remotes from", into.filter(".remote").map((e) => ({ node: e.source(), note: e.data("label") })));

  body.innerHTML = html;
  if (f) drawDiff($("diff"), f);
}

function renderFile(body, f) {
  const [dir, base] = split(f.path);
  body.innerHTML = `<button class="back" data-back>← ${esc(backLabel())}</button>
    <h2>${esc(base)}</h2>
    <div class="meta">${esc(dir || ".")}${f.oldPath ? ` · was ${esc(f.oldPath)}` : ""}</div>
    <h3>In this change &nbsp;<span class="status ${f.status}">${f.status}</span> ${f.binary ? "" : counts(f.additions, f.deletions)}</h3>
    <div id="note" data-path="${esc(f.path)}">${noteHtml(f.path)}</div>
    <div class="diff" id="diff"></div>`;
  drawDiff($("diff"), f);
}

async function drawDiff(el, f) {
  el.innerHTML = `<p class="meta">Loading diff…</p>`;
  const query = new URLSearchParams({ ref: state.change.ref, path: f.path, ...(f.oldPath ? { old: f.oldPath } : {}) });
  const text = await (await api(`/api/diff?${query}`)).text();
  if (!el.isConnected) return;
  if (!text.trim() || f.binary) {
    el.innerHTML = `<p class="empty">${f.binary ? "Binary file." : "No line changes."}</p>`;
    return;
  }
  el.innerHTML = "";
  const ui = new Diff2HtmlUI(el, text, {
    drawFileList: false,
    matching: "lines",
    outputFormat: document.body.classList.contains("wide") ? "side-by-side" : "line-by-line",
    highlight: true,
    colorScheme: "dark",
    fileContentToggle: false,
    synchronisedScroll: true,
  });
  ui.draw();
  ui.highlightCode();
}

function renderPanel() {
  const body = $("panel-body");
  const node = state.selected ? cy.getElementById(state.selected) : null;
  if (node && node.nonempty()) renderNode(body, node);
  else if (state.file) renderFile(body, state.file);
  else renderSummary(body);
}

function selectNode(id, { center = false } = {}) {
  const node = cy.getElementById(id);
  if (node.empty()) return;
  state.selected = id;
  state.file = null;
  cy.elements(":selected").unselect();
  node.select();
  if (center) cy.animate({ center: { eles: node }, duration: 250 });
  showLinks();
  renderPanel();
}

function clearSelection() {
  state.selected = null;
  state.file = null;
  cy.elements(":selected").unselect();
  showLinks();
  renderPanel();
}

// ---------------------------------------------------------------- wiring

function wire() {
  cy.on("tap", "node", (e) => selectNode(e.target.id()));
  cy.on("tap", (e) => {
    if (e.target === cy) clearSelection();
  });
  cy.on("dragfree", "node", savePositions);
  cy.on("mouseover", "node", (e) => showTip(e.target));
  cy.on("mouseout", "node", hideTip);
  cy.on("viewport tapstart", hideTip);

  $("older").onclick = () => step(1);
  $("newer").onclick = () => step(-1);
  $("change-button").onclick = (e) => {
    e.stopPropagation();
    toggleCommits();
  };
  $("commits").onclick = (e) => {
    const ref = e.target.closest("[data-ref]")?.dataset.ref;
    if (!ref) return;
    toggleCommits(false);
    selectChange(ref);
  };
  $("commits").onscroll = () => {
    const box = $("commits");
    if (box.scrollTop + box.clientHeight > box.scrollHeight - 120) loadMore().then(renderCommits);
  };
  document.addEventListener("click", (e) => {
    if (!$("commits").hidden && !e.target.closest("#commits")) toggleCommits(false);
  });

  for (const button of document.querySelectorAll("[data-links]")) {
    button.onclick = () => {
      state.links = button.dataset.links;
      for (const b of document.querySelectorAll("[data-links]")) b.classList.toggle("on", b === button);
      showLinks();
    };
  }

  $("panel-body").onclick = (e) => {
    if (e.target.closest("[data-back]")) return clearSelection();
    const nodeId = e.target.closest("[data-node]")?.dataset.node;
    if (nodeId) return selectNode(nodeId, { center: true });
    const path = e.target.closest("[data-path]")?.dataset.path;
    if (!path) return;
    const f = state.change.files.find((x) => x.path === path);
    const id = nodeFor(f);
    if (id && cy.getElementById(id).nonempty()) return selectNode(id, { center: true });
    state.selected = null;
    state.file = f;
    cy.elements(":selected").unselect();
    showLinks();
    renderPanel();
  };

  const search = $("search");
  search.oninput = () => {
    const q = search.value.trim().toLowerCase();
    cy.nodes().removeClass("match");
    if (q) cy.nodes().filter((n) => n.data("label").toLowerCase().includes(q)).addClass("match");
  };
  search.onkeydown = (e) => {
    if (e.key === "Enter") {
      const q = search.value.trim().toLowerCase();
      const matches = cy.nodes(".match");
      const best = matches.filter((n) => n.data("label").toLowerCase() === q).first();
      const pick = best.nonempty() ? best : matches.filter((n) => n.data("label").toLowerCase().startsWith(q)).first();
      const node = pick.nonempty() ? pick : matches.first();
      if (node.nonempty()) {
        selectNode(node.id());
        cy.animate({ fit: { eles: node.closedNeighborhood(), padding: 80 }, duration: 300 });
      }
    }
    if (e.key === "Escape") {
      search.value = "";
      cy.nodes().removeClass("match");
      search.blur();
    }
  };

  $("fit").onclick = () => cy.animate({ fit: { padding: 30 }, duration: 250 });
  $("relayout").onclick = () => {
    relayout();
    savePositions();
    cy.animate({ fit: { padding: 30 }, duration: 250 });
  };
  $("expand").onclick = () => {
    document.body.classList.toggle("wide");
    $("expand").textContent = document.body.classList.contains("wide") ? "Narrow" : "Widen";
    cy.resize();
    renderPanel();
  };

  document.addEventListener("keydown", (e) => {
    if (e.target.closest("input")) return;
    if (e.key === "ArrowLeft") step(1);
    else if (e.key === "ArrowRight") step(-1);
    else if (e.key === "/") {
      e.preventDefault();
      search.focus();
    } else if (e.key === "f") $("fit").click();
    else if (e.key === "e") $("expand").click();
    else if (e.key === "Escape") {
      if (!$("commits").hidden) toggleCommits(false);
      else clearSelection();
    }
  });
}

// A new stylesheet first, then the graph's colours, which cytoscape keeps as
// values rather than CSS variables.
function reloadTheme() {
  const old = $("theme");
  const next = old.cloneNode();
  next.href = `/theme.css?${Date.now()}`;
  next.onload = () => {
    old.remove();
    cy.style(styles());
  };
  old.after(next);
}

function listen() {
  const events = new EventSource("/events");
  events.onmessage = async (message) => {
    const event = JSON.parse(message.data);
    if (event.theme) reloadTheme();
    if (event.graph) await reloadGraph();
    if (event.explanations) {
      await loadDescription({ fromEvent: true, structure: false });
      const commit = state.commits.find((c) => c.hash === state.change?.ref);
      if (commit && state.explanation?.summary) commit.explained = true;
      if (!$("commits").hidden) renderCommits();
    }
    if (event.head || event.worktree) await refreshGit();
  };
}

async function main() {
  const [graph, layout] = await Promise.all([api("/api/graph").then((r) => r.json()), api("/api/layout").then((r) => r.json())]);
  const saved = layout.version === LAYOUT_VERSION ? layout.positions : {};
  state.graph = graph;
  document.title = `${graph.project} · codegraph`;
  $("project").textContent = graph.project;

  cy = cytoscape({
    container: $("graph"),
    elements: elements(graph),
    style: styles(),
    layout: { name: "preset" },
    minZoom: 0.05,
    maxZoom: 3,
    boxSelectionEnabled: false,
  });
  place(saved);
  focusChange(false);
  askForPurposes();
  wire();

  await loadMore();
  await selectChange(currentRef());
  listen();
}

main().catch((error) => {
  $("panel-body").innerHTML = `<p class="empty">${esc(error.message)}</p>`;
  console.error(error);
});
