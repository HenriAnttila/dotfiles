#!/usr/bin/env bun
// Writes codegraph's descriptions of changes: a summary, the changed files
// grouped by feature, and for each file what changed and why.
//
//   explain.ts <project> commit <hash> [--session <id> --cwd <dir>]
//   explain.ts <project> worktree
//
// hook.ts runs the commit form right after Claude commits, naming the session
// that made the commit; server.ts runs either form when the page shows a change
// that has no description yet. Both start it detached, so it finishes and
// saves even if the page or the CLI is gone by then.
//
// With a session, the description comes from a fork of that session
// (claude -p --resume <id> --fork-session): it has the whole conversation, so it
// knows why. The fork is not saved, and gets no tools: everything it needs is in
// the prompt, and it answers in a fixed JSON shape. Without a session, or when
// the session can't be resumed, a fresh claude -p works from the diff alone.
//
// Uncommitted work is described per session: the files store.ts says each
// session changed go to a fork of that session, the rest to a fresh run.
//
// CODEGRAPH_FORK is set for every claude it starts, so hook.ts ignores the
// tool calls those make and a description never sets off another.

import { Repo, WORKTREE, type ChangedFile } from "./git.ts";
import { type Description, type Sessions, Store } from "./store.ts";
import { describe, structure } from "./structure.ts";

const SCHEMA = {
  type: "object",
  required: ["summary", "features", "files"],
  properties: {
    summary: { type: "string" },
    features: {
      type: "array",
      items: {
        type: "object",
        required: ["name", "description", "files"],
        properties: { name: { type: "string" }, description: { type: "string" }, files: { type: "array", items: { type: "string" } } },
      },
    },
    files: {
      type: "array",
      items: {
        type: "object",
        required: ["path", "what", "why"],
        properties: { path: { type: "string" }, what: { type: "string" }, why: { type: "string" } },
      },
    },
  },
};

const NO_TOOLS = "Bash Edit Write MultiEdit NotebookEdit Read Grep Glob LS WebFetch WebSearch Agent Task TodoWrite Skill";
const LINES_PER_FILE = 300;
const DIFF_BUDGET = 80_000;
const TIMEOUT_MS = 5 * 60_000;

type Session = { id: string; cwd: string };

function diffs(repo: Repo, ref: string, files: ChangedFile[]): string {
  let budget = DIFF_BUDGET;
  const parts = [];
  for (const f of files) {
    if (f.binary) continue;
    let text = repo.diff(ref, f.path, f.oldPath);
    const lines = text.split("\n");
    if (lines.length > LINES_PER_FILE) text = `${lines.slice(0, LINES_PER_FILE).join("\n")}\n… (${lines.length - LINES_PER_FILE} more lines)`;
    if (text.length > budget) {
      parts.push(`(diff of ${f.path} left out: too long)`);
      continue;
    }
    budget -= text.length;
    parts.push(text);
  }
  return parts.join("\n");
}

const listing = (files: ChangedFile[]) =>
  files.map((f) => `${f.status} ${f.path}${f.oldPath ? ` (was ${f.oldPath})` : ""}${f.binary ? " (binary)" : ` +${f.additions} -${f.deletions}`}`).join("\n");

function prompt(o: { what: string; forked: boolean; header: string; structure: string; files: ChangedFile[]; others?: ChangedFile[]; diff: string }) {
  return `codegraph, the tool that maps this project and shows its changes, needs a description of ${o.what}.
${
  o.forked
    ? "You are a fork of the session that made these changes. Say why from what you know of that work, not only from what the diff shows."
    : "Work from the diff. Where the reason isn't clear from it, say what the change does rather than guess at why."
}

Keep every text short: a sentence or two, in plain words, without file paths in the prose.

- summary: what this change does to the game, and why.
- features: group the changed files by the feature they serve. For each, a short name (a few words) and a description of what changed for that feature, structurally (the modules and links that came or went, from the structure list below) and why. Every file belongs to exactly one feature.
- files: one entry per changed file, with the path exactly as listed. what: what code changed in it, concretely (functions, fields, behaviour). why: why it changed.

${o.header}

Structure (worked out from the code, not a guess: modules and links added or removed):
${o.structure}

Changed files to describe:
${listing(o.files)}
${o.others?.length ? `\nAlso changed, described separately (for context only):\n${listing(o.others)}\n` : ""}
Diffs:
${o.diff}`;
}

async function ask(store: Store, text: string, session?: Session): Promise<(Description & { by: "session" | "diff"; session?: string }) | null> {
  const args = [
    "-p",
    "--output-format",
    "json",
    "--json-schema",
    JSON.stringify(SCHEMA),
    "--no-session-persistence",
    "--disallowedTools",
    NO_TOOLS,
    ...(session ? ["--resume", session.id, "--fork-session"] : []),
  ];
  const proc = Bun.spawn(["claude", ...args], {
    cwd: session?.cwd ?? store.repo.project,
    stdin: "pipe",
    stdout: "pipe",
    stderr: "pipe",
    env: { ...process.env, CODEGRAPH_FORK: "1" },
  });
  const timer = setTimeout(() => proc.kill(), TIMEOUT_MS);
  proc.stdin.write(text);
  proc.stdin.end();
  const [out, err] = await Promise.all([new Response(proc.stdout).text(), new Response(proc.stderr).text()]);
  await proc.exited;
  clearTimeout(timer);

  let result: { is_error?: boolean; structured_output?: { summary: string; features: Description["features"]; files: { path: string; what: string; why: string }[] } } | null = null;
  try {
    result = JSON.parse(out);
  } catch {}
  const answer = result && !result.is_error ? result.structured_output : null;
  if (!answer) {
    store.log(`claude ${session ? `fork of ${session.id}` : "run"} failed: ${(err || out).trim().slice(0, 400)}`);
    return session ? ask(store, text.replace(/^You are a fork[^\n]*\n/m, "Work from the diff. Where the reason isn't clear from it, say what the change does rather than guess at why.\n"), undefined) : null;
  }
  return {
    summary: answer.summary,
    features: answer.features ?? [],
    files: Object.fromEntries((answer.files ?? []).map((f) => [f.path, { what: f.what, why: f.why }])),
    by: session ? "session" : "diff",
    ...(session ? { session: session.id } : {}),
  };
}

async function explainCommit(store: Store, ref: string, session?: Session) {
  const repo = store.repo;
  const commit = repo.commit(ref);
  if (!commit || store.note(commit.hash) || !store.claim(commit.hash)) return;
  try {
    const files = repo.changes(commit.hash);
    const message = repo.run(["log", "-1", "--format=%B", commit.hash]).trim();
    const text = prompt({
      what: `commit ${commit.short}`,
      forked: !!session,
      header: `Commit ${commit.short}:\n${message}`,
      structure: describe(structure(repo, commit.hash)),
      files,
      diff: diffs(repo, commit.hash, files),
    });
    const answer = await ask(store, text, session);
    if (answer) store.writeNote(commit.hash, { version: 1, at: new Date().toISOString(), ...answer });
  } finally {
    store.release(commit.hash);
  }
}

async function explainWorktree(store: Store) {
  const repo = store.repo;
  if (!store.claim(WORKTREE)) return;
  try {
    // Files that change again while a round runs are picked up by the next.
    for (let round = 0; round < 3; round++) {
      const prints = store.fingerprints();
      const view = store.worktree(prints);
      if (!view.pending.length) return;
      const sessions = store.read<Sessions>("sessions.json", { head: null, sessions: {}, files: {} }).sessions;
      const all = repo.changes(WORKTREE);
      const text = describe(structure(repo, WORKTREE));
      const groups = new Map<string | null, string[]>();
      for (const path of view.pending) {
        const id = view.sessions[path] && sessions[view.sessions[path]!] ? view.sessions[path] : null;
        groups.set(id, [...(groups.get(id) ?? []), path]);
      }
      for (const [id, paths] of groups) {
        const files = all.filter((f) => paths.includes(f.path));
        const answer = await ask(
          store,
          prompt({
            what: "the uncommitted changes in this project",
            forked: !!id,
            header: "Uncommitted changes, against HEAD.",
            structure: text,
            files,
            others: all.filter((f) => !paths.includes(f.path)),
            diff: diffs(repo, WORKTREE, files),
          }),
          id ? { id, cwd: sessions[id].cwd } : undefined,
        );
        if (!answer) continue;
        const { by: _, session: __, ...description } = answer;
        store.addWorktreeEntry({
          ...description,
          at: new Date().toISOString(),
          session: id,
          fingerprints: Object.fromEntries(paths.map((p) => [p, prints[p]])),
        });
      }
    }
  } finally {
    store.release(WORKTREE);
  }
}

if (import.meta.main) {
  const [project, mode, ref] = process.argv.slice(2);
  const flag = (name: string) => {
    const at = process.argv.indexOf(name);
    return at > 0 ? process.argv[at + 1] : undefined;
  };
  const store = new Store(new Repo(project));
  try {
    if (mode === "commit" && ref) {
      const id = flag("--session");
      await explainCommit(store, ref, id ? { id, cwd: flag("--cwd") ?? project } : undefined);
    } else if (mode === "worktree") {
      await explainWorktree(store);
    } else {
      console.error("usage: explain.ts <project> commit <hash> [--session <id> --cwd <dir>] | worktree");
      process.exit(2);
    }
  } catch (error) {
    store.log(`explain ${mode} ${ref ?? ""}: ${error instanceof Error ? error.stack : error}`);
  }
}
