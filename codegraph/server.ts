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
// Node positions are kept in .git/codegraph/layout.json in the project's
// repository, so the map stays the same between runs and never gets committed.

import { existsSync, mkdirSync, readFileSync, watch, writeFileSync } from "node:fs";
import { basename, dirname, join, relative, resolve } from "node:path";
import { buildGraph } from "./graph.ts";
import { Repo, WORKTREE } from "./git.ts";

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
let pending = { graph: false, git: false };
let timer: Timer | null = null;
let last = { head: repo.head(), status: repo.status() };

const flush = () => {
  timer = null;
  const event = { graph: pending.graph, head: false, worktree: false };
  if (pending.git) {
    const now = { head: repo.head(), status: repo.status() };
    event.head = now.head !== last.head;
    event.worktree = event.head || now.status !== last.status;
    last = now;
  }
  pending = { graph: false, git: false };
  if (event.graph || event.head || event.worktree) broadcast(event);
};

const changed = (file: string, inGitDir: boolean) => {
  if (inGitDir) {
    if (!/^(HEAD|index|packed-refs|refs\/)/.test(file)) return;
    pending.git = true;
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

const json = (data: unknown, status = 200) => Response.json(data, { status });

const routes: Record<string, (url: URL, req: Request) => Response | Promise<Response>> = {
  "/": () => new Response(Bun.file(join(here, "index.html"))),
  "/app.js": () => new Response(Bun.file(join(here, "app.js"))),
  "/style.css": () => new Response(Bun.file(join(here, "style.css"))),

  "/api/graph": () => json({ project: basename(project), ...buildGraph(project) }),

  "/api/commits": (url) => {
    const skip = Number(url.searchParams.get("skip") ?? 0);
    const limit = Math.min(Number(url.searchParams.get("limit") ?? 50), 500);
    return json({ dirty: repo.status() !== "", commits: repo.commits(skip, limit) });
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
    if (attempt >= 20 || !String(error).includes("EADDRINUSE")) throw error;
  }
}
