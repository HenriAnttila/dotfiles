#!/usr/bin/env bun
// codegraph: a Rojo project as a graph in the browser, with a change lit up on
// it. Run it in the project (the folder with sourcemap.json) or pass the path:
//
//   ~/dotfiles/codegraph/server.ts [project] [--port 7420]
//
// It prints the address and serves until stopped. A taken port moves on to the
// next one, so two projects can be open at once. It only listens on 127.0.0.1.
//
// The page asks for everything when it needs it: the graph, a page of commits,
// the files one change touched, one file's diff. Nothing is worked out ahead of
// time. The server watches the project and tells the open page over
// server-sent events when the graph or git changed, so a save or a commit shows
// up without a reload.
//
// Colours and font come from Ghostty and tmux (theme.ts), and follow a theme
// pick while the page is open.
//
// Descriptions of changes (explain.ts, kept by store.ts) are written when the
// page shows a change that has none, and after Claude commits (hook.ts). The
// page hears when one lands.
//
// Node positions are kept in .git/codegraph/layout.json in the project's
// repository, so the map stays the same between runs and never gets committed.

import { spawn } from "node:child_process";
import { existsSync, mkdirSync, readFileSync, watch, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { Repo, WORKTREE } from "./git.ts";
import { Store } from "./store.ts";
import { liveGraph, structure } from "./structure.ts";
import { GHOSTTY_DIR, themeCss } from "./theme.ts";

let project = process.cwd();
let port = 7420;
const args = process.argv.slice(2);
for (let i = 0; i < args.length; i++) {
  if (args[i] === "--port") port = Number(args[++i]);
  else project = resolve(args[i]);
}

if (!existsSync(join(project, "sourcemap.json"))) {
  console.error(`codegraph: no sourcemap.json in ${project}`);
  console.error("  rojo sourcemap -o sourcemap.json   writes one");
  process.exit(1);
}

const repo = new Repo(project);
const store = new Store(repo);
const here = import.meta.dir;
const layoutFile = join(repo.gitDir, "codegraph", "layout.json");

const encoder = new TextEncoder();
const clients = new Set<ReadableStreamDefaultController<Uint8Array>>();
const send = (controller: ReadableStreamDefaultController<Uint8Array>, text: string) => {
  try {
    controller.enqueue(encoder.encode(text));
  } catch {
    clients.delete(controller);
  }
};
const broadcast = (event: object) => {
  for (const c of clients) send(c, `data: ${JSON.stringify(event)}\n\n`);
};

// Saves and git both fire many file events at once; they are gathered for a
// moment and the page hears about them once. Git counts as changed only when
// HEAD or the status output differs from last time, so a save that git ignores
// does not make the page reload a change.
let pending = { graph: false, git: false, explanations: false, purposes: false };
let timer: Timer | null = null;
let last = { head: repo.head(), status: repo.status() };

const flush = () => {
  timer = null;
  const event = { graph: pending.graph || pending.purposes, head: false, worktree: false, explanations: pending.explanations };
  if (pending.git) {
    const now = { head: repo.head(), status: repo.status() };
    event.head = now.head !== last.head;
    event.worktree = event.head || now.status !== last.status;
    last = now;
  }
  pending = { graph: false, git: false, explanations: false, purposes: false };
  if (event.graph || event.head || event.worktree || event.explanations) broadcast(event);
};

const changed = (file: string, inGitDir: boolean) => {
  if (inGitDir) {
    if (/^codegraph\/purposes\.json/.test(file)) pending.purposes = true;
    else if (/^(refs\/notes\/|codegraph\/(worktree\.json|jobs\/))/.test(file)) pending.explanations = true;
    else if (/^(HEAD|index|packed-refs|refs\/)/.test(file)) pending.git = true;
    else return;
  } else {
    if (file === "sourcemap.json" || /\.luau?$/.test(file)) pending.graph = true;
    pending.git = true;
  }
  timer ??= setTimeout(flush, 300);
};

const gitInProject = !relative(project, repo.gitDir).startsWith("..");
watch(project, { recursive: true }, (_, file) => {
  if (!file) return;
  const path = file.toString();
  const inGit = gitInProject && (path === ".git" || path.startsWith(".git/"));
  changed(inGit ? path.replace(/^\.git\/?/, "") : path, inGit);
});
if (!gitInProject) watch(repo.gitDir, { recursive: true }, (_, file) => file && changed(file.toString(), true));

// A theme pick rewrites Ghostty's theme.generated; the page swaps in the new colours.
let themeTimer: Timer | null = null;
if (existsSync(GHOSTTY_DIR)) {
  watch(GHOSTTY_DIR, () => {
    themeTimer ??= setTimeout(() => {
      themeTimer = null;
      broadcast({ theme: true });
    }, 300);
  });
}

const json = (data: unknown, status = 200) => Response.json(data, { status });

const refFrom = (url: URL): string | null => {
  const ref = url.searchParams.get("ref") ?? WORKTREE;
  return ref === WORKTREE ? ref : (repo.commit(ref)?.hash ?? null);
};

// The page asks for a description when it shows a change that has none. Each
// one is tried once per run of the server: a commit by its hash, the
// uncommitted work by the files and diffs still waiting, so a description that
// fails is not retried in a loop, but new uncommitted changes are.
const tried = new Set<string>();
function explain(ref: string): boolean {
  if (store.running(ref)) return false;
  let key = ref;
  if (ref === "purposes") {
    const purposes = store.read<Record<string, { hash: string }>>("purposes.json", {});
    const missing = liveGraph(project).nodes.filter((n) => n.kind === "script" && !n.external && !n.doc && purposes[n.id]?.hash !== n.hash);
    if (!missing.length) return false;
    key = `purposes:${missing.map((n) => `${n.id}:${n.hash}`).sort().join("|")}`;
  } else if (ref === WORKTREE) {
    const prints = store.fingerprints();
    const waiting = store.worktree(prints).pending;
    if (!waiting.length) return false;
    key = waiting.map((p) => `${p}:${prints[p]}`).sort().join("|");
  } else if (store.note(ref)) {
    return false;
  }
  if (tried.has(key)) return false;
  tried.add(key);
  const mode = ref === WORKTREE || ref === "purposes" ? [ref === WORKTREE ? "worktree" : "purposes"] : ["commit", ref];
  spawn(process.execPath, [join(here, "explain.ts"), project, ...mode], {
    detached: true,
    stdio: "ignore",
  }).unref();
  return true;
}

const routes: Record<string, (url: URL, req: Request) => Response | Promise<Response>> = {
  "/": () => new Response(Bun.file(join(here, "index.html"))),
  "/app.js": () => new Response(Bun.file(join(here, "app.js"))),
  "/style.css": () => new Response(Bun.file(join(here, "style.css"))),
  "/theme.css": () => new Response(themeCss(), { headers: { "content-type": "text/css", "cache-control": "no-store" } }),

  // Each script that doesn't open with a comment gets the sentence explain.ts
  // wrote for it, while that sentence still matches the file.
  "/api/graph": () => {
    const graph = liveGraph(project);
    const purposes = store.read<Record<string, { hash: string; text: string }>>("purposes.json", {});
    for (const n of graph.nodes) {
      const p = purposes[n.id];
      if (!n.doc && p && p.hash === n.hash) n.purpose = p.text;
    }
    return json({ project: basename(project), ...graph });
  },

  "/api/purposes": (_, req) => {
    if (req.method !== "POST") return json({ error: "POST to start" }, 400);
    return json({ started: explain("purposes") });
  },

  "/api/commits": (url) => {
    const skip = Number(url.searchParams.get("skip") ?? 0);
    const limit = Math.min(Number(url.searchParams.get("limit") ?? 50), 500);
    const noted = store.noted();
    const commits = repo.commits(skip, limit).map((c) => ({ ...c, explained: noted.has(c.hash) }));
    return json({ dirty: repo.status() !== "", commits });
  },

  "/api/change": (url) => {
    const ref = url.searchParams.get("ref") ?? WORKTREE;
    if (ref === WORKTREE) return json({ ref, commit: null, files: repo.changes(ref) });
    const commit = repo.commit(ref);
    if (!commit) return json({ error: `no commit ${ref}` }, 404);
    return json({ ref: commit.hash, commit, files: repo.changes(commit.hash) });
  },

  "/api/diff": (url) => {
    const ref = url.searchParams.get("ref") ?? WORKTREE;
    const path = url.searchParams.get("path");
    if (!path || (ref !== WORKTREE && !repo.commit(ref))) return new Response("", { status: 400 });
    return new Response(repo.diff(ref, path, url.searchParams.get("old") ?? undefined));
  },

  "/api/structure": (url) => {
    const ref = refFrom(url);
    return ref ? json(structure(repo, ref)) : json({ error: "no such change" }, 404);
  },

  // A commit's git note, or the uncommitted work as described so far, with the
  // files still waiting. `running` while a description is being written.
  "/api/explanation": (url) => {
    const ref = refFrom(url);
    if (!ref) return json({ error: "no such change" }, 404);
    if (ref === WORKTREE) return json({ ...store.worktree(), running: store.running(WORKTREE) });
    const note = store.note(ref);
    return json({ ...(note ?? { features: [], files: {} }), pending: note ? [] : null, running: store.running(ref) });
  },

  "/api/explain": (url, req) => {
    const ref = refFrom(url);
    if (req.method !== "POST" || !ref) return json({ error: "POST a change" }, 400);
    return json({ started: explain(ref) });
  },

  "/api/layout": async (_, req) => {
    if (req.method === "PUT") {
      mkdirSync(dirname(layoutFile), { recursive: true });
      writeFileSync(layoutFile, JSON.stringify(await req.json()));
      return json({ ok: true });
    }
    return json(existsSync(layoutFile) ? JSON.parse(readFileSync(layoutFile, "utf8")) : {});
  },

  "/events": (_, req) => {
    let ping: Timer;
    let self: ReadableStreamDefaultController<Uint8Array>;
    const stream = new ReadableStream<Uint8Array>({
      start(controller) {
        self = controller;
        clients.add(controller);
        send(controller, ": connected\n\n");
        ping = setInterval(() => send(controller, ": ping\n\n"), 15000);
        req.signal.addEventListener("abort", () => {
          clearInterval(ping);
          clients.delete(controller);
        });
      },
      cancel() {
        clearInterval(ping);
        clients.delete(self);
      },
    });
    return new Response(stream, {
      headers: { "content-type": "text/event-stream", "cache-control": "no-store", connection: "keep-alive" },
    });
  },
};

const fetch = async (req: Request) => {
  const url = new URL(req.url);
  const route = routes[url.pathname];
  if (!route) return new Response("not found", { status: 404 });
  try {
    return await route(url, req);
  } catch (error) {
    console.error(error);
    return json({ error: String(error) }, 500);
  }
};

for (let attempt = 0; ; attempt++) {
  try {
    const server = Bun.serve({ hostname: "127.0.0.1", port: port + attempt, fetch, idleTimeout: 60 });
    console.log(`codegraph: ${basename(project)} on http://localhost:${server.port}`);
    break;
  } catch (error) {
    if (attempt >= 20 || (error as { code?: string }).code !== "EADDRINUSE") throw error;
  }
}
