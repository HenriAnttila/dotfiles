// What a change did to the project's structure: the graph before it and after
// it, compared. Modules added or removed, and links (requires, the services the
// Loader starts, remotes) that appeared or went away.
//
// Each side gets a sourcemap from Rojo, written for that exact tree. The one
// committed in the repo can't be trusted for this: it is only refreshed while
// `rojo serve` runs, and most commits that add or remove a script leave it
// behind. A commit's tree is unpacked with `git archive` into a temporary
// folder first; the uncommitted side is the project folder itself.
//
// Rojo always runs from the live project, so rokit picks its version from the
// project's rokit.toml, even for a commit older than that file.

import { existsSync, mkdtempSync, readdirSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildGraph, type Graph, type GraphEdge } from "./graph.ts";
import { type Repo, WORKTREE } from "./git.ts";

export type Module = { id: string; label: string; parent?: string };
export type Link = { kind: GraphEdge["kind"]; source: string; target: string; label?: string };
export type Structure = {
  modules: { added: Module[]; removed: Module[] };
  links: { added: Link[]; removed: Link[] };
};

const EMPTY: Graph = { nodes: [], edges: [], files: {}, unresolved: [] };

function projectFile(dir: string): string | null {
  if (existsSync(join(dir, "default.project.json"))) return "default.project.json";
  return readdirSync(dir).find((f) => f.endsWith(".project.json")) ?? null;
}

function sourcemap(project: string, dir: string, out: string): boolean {
  const file = projectFile(dir);
  if (!file) return false;
  const result = Bun.spawnSync(["rojo", "sourcemap", join(dir, file), "-o", out], { cwd: project, stdout: "ignore", stderr: "ignore" });
  return result.exitCode === 0 && existsSync(out);
}

function scratch<T>(fn: (dir: string) => T): T {
  const dir = mkdtempSync(join(tmpdir(), "codegraph-"));
  try {
    return fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// The project as it is on disk, with a sourcemap Rojo writes just for this; the
// project's own sourcemap.json if Rojo can't run.
export function liveGraph(project: string): Graph {
  return scratch((dir) => {
    const out = join(dir, "sourcemap.json");
    return sourcemap(project, project, out) ? buildGraph(project, out) : buildGraph(project);
  });
}

// A commit's tree never changes, so its graph is kept by its hash.
const commitGraphs = new Map<string, Graph>();

export function graphAt(repo: Repo, rev: string): Graph {
  const hash = repo.run(["rev-parse", "--verify", "--quiet", `${rev}^{commit}`], [1]).trim();
  const kept = hash && commitGraphs.get(hash);
  if (kept) return kept;
  const graph = unpackGraph(repo, hash || rev);
  if (hash) commitGraphs.set(hash, graph);
  return graph;
}

function unpackGraph(repo: Repo, rev: string): Graph {
  return scratch((dir) => {
    const unpacked = Bun.spawnSync(["sh", "-c", 'git -C "$1" archive "$2" | tar -x -C "$3"', "sh", repo.top, rev, dir], {
      stdout: "ignore",
      stderr: "ignore",
    });
    const root = join(dir, repo.prefix);
    if (unpacked.exitCode !== 0 || !existsSync(root)) return EMPTY;
    const out = join(dir, ".codegraph-sourcemap.json");
    if (sourcemap(repo.project, root, out)) return buildGraph(root, out);
    return existsSync(join(root, "sourcemap.json")) ? buildGraph(root) : EMPTY;
  });
}

const scripts = (graph: Graph) => new Map(graph.nodes.filter((n) => n.kind === "script" && !n.external).map((n) => [n.id, n]));

// A remote link carries every remote between two scripts in one label; each
// remote counts as its own link here, so a new remote between the same two
// scripts still shows up.
function links(graph: Graph): Map<string, Link> {
  const found = new Map<string, Link>();
  for (const e of graph.edges) {
    for (const label of e.label ? e.label.split(", ") : [undefined]) {
      found.set(`${e.kind}:${e.source}->${e.target}:${label ?? ""}`, {
        kind: e.kind,
        source: e.source,
        target: e.target,
        ...(label ? { label } : {}),
      });
    }
  }
  return found;
}

export function compare(before: Graph, after: Graph): Structure {
  const [a, b] = [scripts(before), scripts(after)];
  const [la, lb] = [links(before), links(after)];
  const module = (n: { id: string; label: string; parent?: string }) => ({ id: n.id, label: n.label, ...(n.parent ? { parent: n.parent } : {}) });
  return {
    modules: {
      added: [...b.values()].filter((n) => !a.has(n.id)).map(module),
      removed: [...a.values()].filter((n) => !b.has(n.id)).map(module),
    },
    links: {
      added: [...lb].filter(([k]) => !la.has(k)).map(([, l]) => l),
      removed: [...la].filter(([k]) => !lb.has(k)).map(([, l]) => l),
    },
  };
}

const cache = new Map<string, Structure>();

// A commit compares with its first parent (nothing, for the first commit); the
// uncommitted work compares with HEAD. Commits never change, so they are kept.
export function structure(repo: Repo, ref: string, live: () => Graph = () => liveGraph(repo.project)): Structure {
  if (ref === WORKTREE) return compare(repo.head() ? graphAt(repo, "HEAD") : EMPTY, live());
  const hit = cache.get(ref);
  if (hit) return hit;
  const parent = repo.run(["rev-parse", "--verify", "--quiet", `${ref}^`], [1]).trim();
  const result = compare(parent ? graphAt(repo, parent) : EMPTY, graphAt(repo, ref));
  cache.set(ref, result);
  return result;
}

const name = (id: string) => id.split("/").at(-1);
const VERB = { require: "requires", starts: "starts", remote: "fires" } as const;

// The same, as lines a person or a model can read.
export function describe(s: Structure): string {
  const lines = [
    ...s.modules.added.map((m) => `+ module ${m.id.split("/").join(".")}`),
    ...s.modules.removed.map((m) => `- module ${m.id.split("/").join(".")}`),
    ...s.links.added.map((l) => `+ ${name(l.source)} ${VERB[l.kind]} ${name(l.target)}${l.label ? ` (${l.label})` : ""}`),
    ...s.links.removed.map((l) => `- ${name(l.source)} ${VERB[l.kind]} ${name(l.target)}${l.label ? ` (${l.label})` : ""}`),
  ];
  return lines.length ? lines.join("\n") : "(no modules or links added or removed)";
}

if (import.meta.main) {
  const { Repo } = await import("./git.ts");
  const repo = new Repo(process.argv[2] ?? process.cwd());
  const started = performance.now();
  const s = structure(repo, process.argv[3] ?? WORKTREE);
  console.log(describe(s));
  console.log(`(${Math.round(performance.now() - started)}ms)`);
}
