// The project as a graph: Rojo's sourcemap gives the instance tree, a scan of
// every script gives the links between them.
//
// Nodes are scripts and the folders (or services) that hold them. A folder only
// appears when a script lives somewhere under it, and wally's Packages/_Index
// is left out: each package shows up once, as the thunk module wally puts in
// Packages.
//
// Links are found without running anything, from the shapes the code takes:
//   require   require(<instance path>) from one script to another
//   starts    Loader.Start(<folder>) to every ModuleScript directly in it
//   remote    a script firing a remote to every script listening on it, matched
//             by the name under Remotes (Remotes.TARDIS.State)
//
// An instance path is followed through game, script, .Parent, .Name, ["Name"],
// :WaitForChild/:FindFirstChild/:GetService("Name") and the file's own locals
// (local library = ReplicatedStorage.Library). Players.LocalPlayer.PlayerScripts
// is StarterPlayerScripts and .PlayerGui is StarterGui, which is where they
// live in the source. Anything else, like a module picked by name at runtime,
// is not found.

import { readFileSync } from "node:fs";
import { join } from "node:path";

type SourcemapNode = {
  name: string;
  className: string;
  filePaths?: string[];
  children?: SourcemapNode[];
};

type Instance = {
  key: string;
  path: string[];
  name: string;
  className: string;
  filePaths: string[];
  children: Instance[];
  parent: Instance | null;
};

export type GraphNode = {
  id: string;
  label: string;
  parent?: string;
  className: string;
  kind: "script" | "folder";
  file?: string;
  external: boolean;
};

export type GraphEdge = {
  id: string;
  source: string;
  target: string;
  kind: "require" | "starts" | "remote";
  label?: string;
};

export type Graph = {
  nodes: GraphNode[];
  edges: GraphEdge[];
  files: Record<string, string>;
  unresolved: { file: string; expression: string }[];
};

const SCRIPT_CLASSES = new Set(["ModuleScript", "Script", "LocalScript"]);
const SEND = new Set(["FireServer", "FireClient", "FireAllClients", "InvokeServer", "InvokeClient"]);

function index(root: SourcemapNode) {
  const byKey = new Map<string, Instance>();
  const walk = (node: SourcemapNode, path: string[], parent: Instance | null): Instance => {
    const instance: Instance = {
      key: path.join("/"),
      path,
      name: node.name,
      className: node.className,
      filePaths: node.filePaths ?? [],
      children: [],
      parent,
    };
    byKey.set(instance.key, instance);
    for (const child of node.children ?? []) instance.children.push(walk(child, [...path, child.name], instance));
    return instance;
  };
  return { root: walk(root, [], null), byKey };
}

// Comments out, strings kept: the paths in WaitForChild("Name") are strings, and
// a comment that mentions require( or Remotes.X.Y must not count. Comment text
// becomes spaces so positions and line numbers stay where they were.
function stripComments(source: string): string {
  let out = "";
  let i = 0;
  while (i < source.length) {
    const c = source[i];
    if (c === '"' || c === "'" || c === "`") {
      let j = i + 1;
      while (j < source.length && source[j] !== c && source[j] !== "\n") j += source[j] === "\\" ? 2 : 1;
      out += source.slice(i, j + 1);
      i = j + 1;
    } else if (c === "[" && /^\[=*\[/.test(source.slice(i, i + 64))) {
      const open = source.slice(i).match(/^\[(=*)\[/)![0];
      const close = "]" + open.slice(1, -1) + "]";
      const end = source.indexOf(close, i + open.length);
      const j = end < 0 ? source.length : end + close.length;
      out += source.slice(i, j);
      i = j;
    } else if (c === "-" && source[i + 1] === "-") {
      const block = source.slice(i + 2).match(/^\[(=*)\[/);
      let j: number;
      if (block) {
        const close = "]" + block[1] + "]";
        const end = source.indexOf(close, i + 2 + block[0].length);
        j = end < 0 ? source.length : end + close.length;
      } else {
        j = source.indexOf("\n", i);
        if (j < 0) j = source.length;
      }
      out += source.slice(i, j).replace(/[^\n]/g, " ");
      i = j;
    } else {
      out += c;
      i++;
    }
  }
  return out;
}

type Value =
  | { kind: "instance"; path: string[] }
  | { kind: "module"; target: string; chain: string[] }
  | { kind: "unknown" };

const UNKNOWN: Value = { kind: "unknown" };

function member(value: Value, name: string): Value {
  if (value.kind === "module") return { kind: "module", target: value.target, chain: [...value.chain, name] };
  if (value.kind !== "instance") return UNKNOWN;
  const path = value.path;
  if (name === "Parent") return path.length ? { kind: "instance", path: path.slice(0, -1) } : UNKNOWN;
  if (path.length === 1 && path[0] === "Players" && name === "LocalPlayer") return { kind: "instance", path: ["@LocalPlayer"] };
  if (path.length === 1 && path[0] === "@LocalPlayer") {
    if (name === "PlayerScripts") return { kind: "instance", path: ["StarterPlayer", "StarterPlayerScripts"] };
    if (name === "PlayerGui") return { kind: "instance", path: ["StarterGui"] };
    return UNKNOWN;
  }
  return { kind: "instance", path: [...path, name] };
}

class Scanner {
  private aliases = new Map<string, number>();
  private resolving = new Set<string>();

  constructor(
    private source: string,
    private self: Instance,
    private resolveModule: (path: string[]) => string | null,
  ) {
    const top = new Map<string, number>();
    const any = new Map<string, number>();
    for (const m of source.matchAll(/^([ \t]*)local[ \t]+([A-Za-z_]\w*)[ \t]*(?::[^=\n]+)?=(?!=)/gm)) {
      const name = m[2];
      const at = m.index! + m[0].length;
      if (m[1] === "" && !top.has(name)) top.set(name, at);
      if (!any.has(name)) any.set(name, at);
    }
    // A top-level local wins over one in a function body with the same name.
    this.aliases = new Map([...any, ...top]);
  }

  // Reads one expression starting at `at` and returns its value and where it ended.
  expression(at: number): { value: Value; end: number } {
    const s = this.source;
    const skip = (i: number) => {
      while (i < s.length && /\s/.test(s[i])) i++;
      return i;
    };
    let i = skip(at);
    let value: Value;

    const word = s.slice(i).match(/^[A-Za-z_]\w*/);
    if (s[i] === "(") {
      const inner = this.expression(i + 1);
      i = skip(inner.end);
      if (s[i] !== ")") return { value: UNKNOWN, end: i };
      value = inner.value;
      i++;
    } else if (!word) {
      return { value: UNKNOWN, end: i };
    } else {
      i += word[0].length;
      const name = word[0];
      if (name === "require" && s[skip(i)] === "(") {
        const inner = this.expression(skip(i) + 1);
        i = skip(inner.end);
        if (s[i] === ")") i++;
        const target = inner.value.kind === "instance" ? this.resolveModule(inner.value.path) : null;
        value = target ? { kind: "module", target, chain: [] } : UNKNOWN;
      } else if (name === "game") {
        value = { kind: "instance", path: [] };
      } else if (name === "script") {
        value = { kind: "instance", path: this.self.path };
      } else {
        value = this.alias(name);
      }
    }

    for (;;) {
      const j = skip(i);
      const dot = s.slice(j).match(/^\.\s*([A-Za-z_]\w*)/);
      if (dot) {
        value = member(value, dot[1]);
        i = j + dot[0].length;
        continue;
      }
      const index = s.slice(j).match(/^\[\s*(["'])([^"'\n]*)\1\s*\]/);
      if (index) {
        value = member(value, index[2]);
        i = j + index[0].length;
        continue;
      }
      const call = s.slice(j).match(/^:\s*(WaitForChild|FindFirstChild|GetService)\s*\(\s*(["'])([^"'\n]*)\2[^)]*\)/);
      if (call) {
        value = member(value, call[3]);
        i = j + call[0].length;
        continue;
      }
      return { value, end: i };
    }
  }

  alias(name: string): Value {
    const at = this.aliases.get(name);
    if (at === undefined || this.resolving.has(name)) return UNKNOWN;
    this.resolving.add(name);
    const { value } = this.expression(at);
    this.resolving.delete(name);
    return value;
  }

  requires(): { target: string | null; expression: string }[] {
    const found = [];
    for (const m of this.source.matchAll(/(?<![\w.:])require\s*\(/g)) {
      const { value, end } = this.expression(m.index!);
      const expression = this.source.slice(m.index!, end).replace(/\s+/g, " ");
      found.push({ target: value.kind === "module" ? value.target : null, expression });
    }
    return found;
  }

  // Loader.Start(folder): the folder whose modules this script starts.
  started(): string[][] {
    const found = [];
    for (const m of this.source.matchAll(/(?<![\w.:])([A-Za-z_]\w*)\s*\.\s*Start\s*\(/g)) {
      const loader = this.alias(m[1]);
      if (loader.kind !== "module" || loader.chain.length || !/(^|\/)Loader$/.test(loader.target)) continue;
      const { value } = this.expression(m.index! + m[0].length);
      if (value.kind === "instance") found.push(value.path);
    }
    return found;
  }

  // Remotes this script fires or listens on, by their name under Remotes.
  remotes(): { name: string; sends: boolean }[] {
    const found = [];
    const pattern =
      /(?<![\w.:])([A-Za-z_]\w*(?:\s*\.\s*[A-Za-z_]\w*)*?)\s*(?::\s*(FireServer|FireClient|FireAllClients|InvokeServer|InvokeClient)|\.\s*(OnServerEvent|OnClientEvent|OnServerInvoke|OnClientInvoke))\b/g;
    for (const m of this.source.matchAll(pattern)) {
      const { value } = this.expression(m.index!);
      const name = remoteName(value, m[3]);
      if (name) found.push({ name, sends: SEND.has(m[2] ?? "") });
    }
    return found;
  }
}

// The value read up to and including .OnClientEvent (when listening) names the
// remote with that last part dropped.
function remoteName(value: Value, listens: string | undefined): string | null {
  let parts: string[];
  if (value.kind === "module" && /(^|\/)Remotes$/.test(value.target)) parts = value.chain;
  else if (value.kind === "instance" && value.path.includes("Remotes")) parts = value.path.slice(value.path.lastIndexOf("Remotes") + 1);
  else return null;
  if (listens) parts = parts.slice(0, -1);
  return parts.length ? parts.join(".") : null;
}

// `sourcemapFile` defaults to the project's own sourcemap.json; structure.ts
// passes one Rojo has just written, since the committed one is often stale.
export function buildGraph(root: string, sourcemapFile = join(root, "sourcemap.json")): Graph {
  const sourcemap: SourcemapNode = JSON.parse(readFileSync(sourcemapFile, "utf8"));
  const { byKey } = index(sourcemap);

  const included = new Set<string>();
  const isScript = (i: Instance) => SCRIPT_CLASSES.has(i.className) && !i.path.includes("_Index");
  const include = (i: Instance) => {
    for (let at: Instance | null = i; at && at.path.length; at = at.parent) {
      if (included.has(at.key)) break;
      included.add(at.key);
    }
  };
  for (const i of byKey.values()) if (isScript(i)) include(i);

  const resolveModule = (path: string[]) => {
    const i = byKey.get(path.join("/"));
    return i && i.className === "ModuleScript" && included.has(i.key) ? i.key : null;
  };

  const nodes: GraphNode[] = [];
  const files: Record<string, string> = {};
  const edges = new Map<string, GraphEdge>();
  const unresolved: Graph["unresolved"] = [];
  const remotes = new Map<string, { senders: Set<string>; receivers: Set<string> }>();

  const addEdge = (source: string, target: string, kind: GraphEdge["kind"], label?: string) => {
    if (source === target) return;
    const id = `${kind}:${source}->${target}`;
    const existing = edges.get(id);
    if (existing && label && !existing.label!.split(", ").includes(label)) existing.label += `, ${label}`;
    if (!existing) edges.set(id, { id, source, target, kind, ...(label ? { label } : {}) });
  };

  for (const key of included) {
    const i = byKey.get(key)!;
    const file = i.filePaths.find((f) => /\.luau?$/.test(f));
    for (const f of i.filePaths) files[f] = key;
    nodes.push({
      id: key,
      label: i.name,
      ...(i.parent && i.parent.path.length ? { parent: i.parent.key } : {}),
      className: i.className,
      kind: isScript(i) ? "script" : "folder",
      ...(file ? { file } : {}),
      external: i.path[1] === "Packages",
    });
    if (!file || !isScript(i) || i.path[1] === "Packages") continue;

    const scanner = new Scanner(stripComments(readFileSync(join(root, file), "utf8")), i, resolveModule);
    for (const r of scanner.requires()) {
      if (r.target) addEdge(key, r.target, "require");
      else unresolved.push({ file, expression: r.expression });
    }
    for (const path of scanner.started()) {
      const folder = byKey.get(path.join("/"));
      for (const child of folder?.children ?? []) if (child.className === "ModuleScript" && included.has(child.key)) addEdge(key, child.key, "starts");
    }
    for (const r of scanner.remotes()) {
      const entry = remotes.get(r.name) ?? { senders: new Set(), receivers: new Set() };
      (r.sends ? entry.senders : entry.receivers).add(key);
      remotes.set(r.name, entry);
    }
  }

  for (const [name, { senders, receivers }] of remotes)
    for (const s of senders) for (const r of receivers) addEdge(s, r, "remote", name);

  return { nodes, edges: [...edges.values()], files, unresolved };
}

if (import.meta.main) {
  const started = performance.now();
  const graph = buildGraph(process.argv[2] ?? process.cwd());
  const count = (kind: string) => graph.edges.filter((e) => e.kind === kind).length;
  console.log(
    `${graph.nodes.length} nodes, ${count("require")} require, ${count("starts")} starts, ${count("remote")} remote links in ${Math.round(performance.now() - started)}ms`,
  );
  for (const u of graph.unresolved) console.log(`unresolved  ${u.file}  ${u.expression}`);
}
