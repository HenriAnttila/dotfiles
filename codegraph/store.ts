// Where codegraph keeps what it learns about changes, all inside the repo's .git
// so nothing ever shows up in `git status`:
//
//   refs/notes/codegraph        a commit's description, as a git note (JSON),
//                               shown by `git log --notes=codegraph` and shared
//                               only if refs/notes/codegraph is pushed
//   .git/codegraph/worktree.json
//                               descriptions of uncommitted work; a git note
//                               needs a commit to hang on
//   .git/codegraph/sessions.json
//                               which Claude session last changed each
//                               uncommitted file, written by hook.ts
//   .git/codegraph/jobs/        one file per description being written, so the
//                               same change is never described twice at once
//   .git/codegraph/log.txt      what went wrong, when something did
//
// worktree.json holds one entry per description run. Each entry records the
// fingerprint (a hash of the file's diff against HEAD) of every file it
// describes, so an entry stops counting for a file as soon as that file
// changes again, and runs that finish in any order can't overwrite each other.

import { appendFileSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Repo, WORKTREE } from "./git.ts";

export type Feature = { name: string; description: string; files: string[] };
export type FileNote = { what: string; why: string };
export type Description = { summary?: string; features: Feature[]; files: Record<string, FileNote> };
export type Note = Description & { version: 1; at: string; by: "session" | "diff"; session?: string };
export type WorktreeEntry = Description & { at: string; session: string | null; fingerprints: Record<string, string> };
export type Sessions = {
  head: string | null;
  sessions: Record<string, { cwd: string }>;
  files: Record<string, { session: string | null; content: string }>;
};

const NOTES = "codegraph";

export class Store {
  readonly dir: string;

  constructor(readonly repo: Repo) {
    this.dir = join(repo.gitDir, "codegraph");
    mkdirSync(join(this.dir, "jobs"), { recursive: true });
  }

  read<T>(name: string, fallback: T): T {
    try {
      return JSON.parse(readFileSync(join(this.dir, name), "utf8"));
    } catch {
      return fallback;
    }
  }

  write(name: string, data: unknown) {
    const file = join(this.dir, name);
    writeFileSync(`${file}.tmp`, JSON.stringify(data, null, 1));
    renameSync(`${file}.tmp`, file);
  }

  log(message: string) {
    appendFileSync(join(this.dir, "log.txt"), `${new Date().toISOString()} ${message}\n`);
  }

  // A lock is a directory, since making one either works or fails at once. One
  // left behind by a crash is taken over after ten seconds.
  lock<T>(name: string, fn: () => T): T {
    const path = join(this.dir, `${name}.lock`);
    for (let tries = 0; ; tries++) {
      try {
        mkdirSync(path);
        break;
      } catch {
        if (tries > 200) {
          rmSync(path, { recursive: true, force: true });
          continue;
        }
        Bun.sleepSync(50);
      }
    }
    try {
      return fn();
    } finally {
      rmSync(path, { recursive: true, force: true });
    }
  }

  note(hash: string): Note | null {
    const out = this.repo.run(["notes", `--ref=${NOTES}`, "show", hash], [1]).trim();
    try {
      return out ? JSON.parse(out) : null;
    } catch {
      return null;
    }
  }

  writeNote(hash: string, note: Note) {
    const file = join(this.dir, `note-${hash}.json`);
    writeFileSync(file, JSON.stringify(note, null, 1));
    try {
      this.repo.run(["notes", `--ref=${NOTES}`, "add", "-f", "-F", file, hash]);
    } finally {
      rmSync(file, { force: true });
    }
  }

  noted(): Set<string> {
    const out = this.repo.run(["notes", `--ref=${NOTES}`, "list"], [1]);
    return new Set(out.split("\n").map((line) => line.split(" ")[1]).filter(Boolean));
  }

  // A job is running while its file names a live process.
  running(key: string): boolean {
    const job = this.read<{ pid: number } | null>(`jobs/${key}.json`, null);
    if (!job) return false;
    try {
      process.kill(job.pid, 0);
      return true;
    } catch {
      rmSync(join(this.dir, "jobs", `${key}.json`), { force: true });
      return false;
    }
  }

  claim(key: string): boolean {
    return this.lock("jobs", () => {
      if (this.running(key)) return false;
      this.write(`jobs/${key}.json`, { pid: process.pid, at: new Date().toISOString() });
      return true;
    });
  }

  release(key: string) {
    rmSync(join(this.dir, "jobs", `${key}.json`), { force: true });
  }

  // What each uncommitted file's diff looks like now, as a short hash.
  fingerprints(): Record<string, string> {
    const prints: Record<string, string> = {};
    for (const f of this.repo.changes(WORKTREE)) {
      prints[f.path] = Bun.hash(this.repo.diff(WORKTREE, f.path, f.oldPath)).toString(36);
    }
    return prints;
  }

  // The uncommitted work as described so far: for every changed file, the
  // newest entry that still matches it. Files no entry matches are pending.
  worktree(prints = this.fingerprints()): Description & { pending: string[]; sessions: Record<string, string | null> } {
    const entries = this.read<{ entries: WorktreeEntry[] }>("worktree.json", { entries: [] }).entries;
    const files: Record<string, FileNote> = {};
    const owner = new Map<string, WorktreeEntry>();
    for (const entry of [...entries].reverse()) {
      for (const [path, print] of Object.entries(entry.fingerprints)) {
        if (prints[path] !== print || owner.has(path)) continue;
        owner.set(path, entry);
        if (entry.files[path]) files[path] = entry.files[path];
      }
    }
    const features: Feature[] = [];
    for (const entry of new Set(owner.values())) {
      for (const feature of entry.features) {
        const mine = feature.files.filter((path) => owner.get(path) === entry);
        if (mine.length) features.push({ ...feature, files: mine });
      }
    }
    const attributed = this.read<Sessions>("sessions.json", { head: null, sessions: {}, files: {} }).files;
    const sessions = Object.fromEntries(Object.keys(prints).map((path) => [path, attributed[path]?.session ?? null]));
    return { features, files, pending: Object.keys(prints).filter((path) => !owner.has(path)), sessions };
  }

  addWorktreeEntry(entry: WorktreeEntry) {
    this.lock("worktree", () => {
      const prints = this.fingerprints();
      const entries = this.read<{ entries: WorktreeEntry[] }>("worktree.json", { entries: [] }).entries;
      const live = entries.filter((e) => Object.entries(e.fingerprints).some(([path, print]) => prints[path] === print));
      this.write("worktree.json", { entries: [...live, entry] });
    });
  }
}

