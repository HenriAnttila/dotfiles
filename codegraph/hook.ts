#!/usr/bin/env bun
// Claude Code PostToolUse hook for codegraph (async, so it never holds up a
// session). It does nothing outside a Rojo project: a folder with
// sourcemap.json at or above the edited file, or above the session's directory
// for a Bash command.
//
// After every Edit, Write or Bash call it records which session last changed
// each uncommitted file, in .git/codegraph/sessions.json. It compares the files
// git calls changed with what was recorded, so a file changed by a Bash command
// (sed, a script, a generator) is caught as well as one edited directly. A file
// that changes between two of this session's tool calls, by hand or by another
// session, is put down to whichever session runs a tool next: the record is a
// good guess, not proof.
//
// The first time it runs in a project, the work already uncommitted is recorded
// with no session, rather than claimed by whichever session happened to be first.
//
// When a Bash command that ran `git commit` moved HEAD, each new commit gets a
// description from a fork of this session: explain.ts runs detached, and writes
// a git note when it is done.
//
// Calls made by codegraph's own claude runs (CODEGRAPH_FORK) are ignored.

import { spawn } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { Repo, WORKTREE } from "./git.ts";
import { type Sessions, Store } from "./store.ts";

type Input = {
  session_id: string;
  transcript_path?: string;
  cwd: string;
  tool_name: string;
  tool_input: { file_path?: string; notebook_path?: string; command?: string };
};

function projectAbove(start: string): string | null {
  for (let dir = start; ; dir = dirname(dir)) {
    if (existsSync(join(dir, "sourcemap.json"))) return dir;
    if (dir === dirname(dir)) return null;
  }
}

// claude --resume finds a session from the directory it was started in, which
// the transcript's first messages carry; the hook's cwd is wherever the
// session's shell has moved to since.
function startedIn(input: Input): string {
  try {
    const head = readFileSync(input.transcript_path!, "utf8").slice(0, 200_000);
    for (const line of head.split("\n")) {
      const cwd = line && JSON.parse(line).cwd;
      if (cwd) return cwd;
    }
  } catch {}
  return input.cwd;
}

function contentHash(path: string): string {
  try {
    return Bun.hash(readFileSync(path)).toString(36);
  } catch {
    return "gone";
  }
}

async function main() {
  if (process.env.CODEGRAPH_FORK) return;
  const input: Input = JSON.parse(await Bun.stdin.text());
  // A Bash command can work on a project other than the session's directory
  // (cd /path && git commit), so the absolute paths in it are tried as well.
  const file = input.tool_input.file_path ?? input.tool_input.notebook_path;
  const places = file ? [dirname(file)] : [input.cwd, ...(input.tool_input.command?.match(/\/[^\s'"`;&|()<>]+/g) ?? [])];
  const project = places.map(projectAbove).find(Boolean);
  if (!project) return;

  const repo = new Repo(project);
  const store = new Store(repo);
  const fresh: string[] = [];

  const session = store.lock("sessions", () => {
    const first = !store.read<Sessions | null>("sessions.json", null);
    const record = store.read<Sessions>("sessions.json", { head: null, sessions: {}, files: {} });
    record.sessions[input.session_id] ??= { cwd: startedIn(input) };

    const changed = new Set(repo.changes(WORKTREE).map((f) => f.path));
    for (const path of Object.keys(record.files)) if (!changed.has(path)) delete record.files[path];
    for (const path of changed) {
      const content = contentHash(path.startsWith("/") ? join(repo.top, path) : join(project, path));
      if (record.files[path]?.content !== content) record.files[path] = { session: first ? null : input.session_id, content };
    }

    const head = repo.head();
    const commits = input.tool_name === "Bash" && /\bgit\b[^\n]*\bcommit\b/.test(input.tool_input.command ?? "");
    if (commits && head && record.head && head !== record.head) {
      const out = repo.run(["rev-list", "--max-count=10", `${record.head}..${head}`], [128]).trim();
      fresh.push(...(out ? out.split("\n") : [head]));
    }
    record.head = head;
    store.write("sessions.json", record);
    return { id: input.session_id, cwd: record.sessions[input.session_id].cwd };
  });

  for (const hash of fresh.reverse()) {
    const child = spawn(process.execPath, [join(import.meta.dir, "explain.ts"), project, "commit", hash, "--session", session.id, "--cwd", session.cwd], {
      detached: true,
      stdio: "ignore",
    });
    child.unref();
  }
}

main().catch(() => {});
