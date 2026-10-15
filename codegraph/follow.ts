// Following Claude while it works, from the session's transcript: what it read
// and what it edited in this project since your last prompt.
//
// Claude Code appends every message to ~/.claude/projects/<dir>/<session>.jsonl
// as it happens, tool calls included, so the transcript is read rather than
// asking hooks for anything. <dir> is the folder the session started in, with
// every character that isn't a letter or digit turned into "-".
//
// The session followed is the one whose transcript was written to last, out of
// the sessions started in the project and the ones hook.ts saw changing it
// (sessions.json), which covers a session started somewhere else that works on
// this project by path.
//
// A prompt you type (a "user" line from a human, not a tool result or a system
// note) starts a new trail. Read marks a file read; Edit, MultiEdit, Write and
// NotebookEdit mark it edited, the moment the call is made; an absolute path in
// a Bash command marks a file read. Files outside the project are left out.
//
// The transcript is read from where it was last read up to its end each time it
// changes; a new or switched transcript is read from its last few megabytes,
// which is plenty to reach its last prompt.

import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join, relative } from "node:path";
import type { Sessions, Store } from "./store.ts";

export const PROJECTS = join(homedir(), ".claude", "projects");
const slug = (dir: string) => dir.replace(/[^a-zA-Z0-9]/g, "-");
const WINDOW = 8 * 1024 * 1024;
const EDITS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);

export type Trail = {
  session: string | null;
  prompt: string | null;
  promptAt: string | null;
  reads: string[];
  edits: string[];
  latest: { path: string; kind: "read" | "edit"; at: string } | null;
  // Kept apart from `latest`, so an edit followed by a read in the same message
  // still reaches the page as an edit.
  lastEdit: { path: string; at: string } | null;
  updatedAt: string | null;
};

const empty = (): Trail => ({ session: null, prompt: null, promptAt: null, reads: [], edits: [], latest: null, lastEdit: null, updatedAt: null });

type Line = {
  type?: string;
  isMeta?: boolean;
  origin?: { kind?: string };
  timestamp?: string;
  message?: { content?: string | { type: string; text?: string; name?: string; input?: Record<string, unknown> }[] };
};

export class Follower {
  private file: string | null = null;
  private offset = 0;
  private rest = "";
  private reads = new Set<string>();
  private edits = new Set<string>();
  trail: Trail = empty();

  constructor(
    private project: string,
    private store: Store,
  ) {}

  private candidates(): string[] {
    const files = new Set<string>();
    const own = join(PROJECTS, slug(this.project));
    if (existsSync(own)) for (const f of readdirSync(own)) if (f.endsWith(".jsonl")) files.add(join(own, f));
    const sessions = this.store.read<Sessions>("sessions.json", { head: null, sessions: {}, files: {} }).sessions;
    for (const [id, s] of Object.entries(sessions)) files.add(join(PROJECTS, slug(s.cwd), `${id}.jsonl`));
    return [...files].filter((f) => existsSync(f));
  }

  // Whether a changed transcript could be one this project follows.
  concerns(path: string): boolean {
    return path.endsWith(".jsonl") && this.candidates().includes(path);
  }

  // Brings the trail up to date; true when it changed.
  refresh(): boolean {
    const latest = this.candidates()
      .map((f) => ({ f, at: statSync(f).mtimeMs }))
      .sort((a, b) => b.at - a.at)[0]?.f ?? null;
    const before = JSON.stringify(this.trail);
    if (latest !== this.file) {
      this.file = latest;
      this.reads.clear();
      this.edits.clear();
      this.trail = empty();
      if (latest) {
        const size = statSync(latest).size;
        this.offset = Math.max(0, size - WINDOW);
        this.rest = "";
        this.readOn(this.offset > 0);
      }
    } else if (latest) {
      this.readOn(false);
    }
    return JSON.stringify(this.trail) !== before;
  }

  private readOn(skipFirstLine: boolean) {
    const file = this.file!;
    const size = statSync(file).size;
    if (size < this.offset) this.offset = 0;
    if (size === this.offset) return;
    const fd = openSync(file, "r");
    const buffer = Buffer.alloc(size - this.offset);
    readSync(fd, buffer, 0, buffer.length, this.offset);
    closeSync(fd);
    this.offset = size;
    const lines = (this.rest + buffer.toString("utf8")).split("\n");
    this.rest = lines.pop() ?? "";
    if (skipFirstLine) lines.shift();
    this.trail.session = file.split("/").at(-1)!.replace(/\.jsonl$/, "");
    for (const line of lines) this.take(line);
  }

  private inProject(path: unknown): string | null {
    if (typeof path !== "string" || !isAbsolute(path)) return null;
    const rel = relative(this.project, path);
    return rel && !rel.startsWith("..") && !isAbsolute(rel) ? rel : null;
  }

  private mark(path: string | null, kind: "read" | "edit", at: string) {
    if (!path) return;
    (kind === "edit" ? this.edits : this.reads).add(path);
    this.trail.reads = [...this.reads].filter((p) => !this.edits.has(p));
    this.trail.edits = [...this.edits];
    this.trail.latest = { path, kind, at };
    if (kind === "edit") this.trail.lastEdit = { path, at };
  }

  private take(text: string) {
    let line: Line;
    try {
      line = JSON.parse(text);
    } catch {
      return;
    }
    const at = line.timestamp ?? new Date().toISOString();
    const content = line.message?.content;
    if (line.type === "user" && !line.isMeta && line.origin?.kind === "human") {
      const prompt = typeof content === "string" ? content : (content ?? []).filter((c) => c.type === "text").map((c) => c.text).join(" ");
      this.reads.clear();
      this.edits.clear();
      this.trail = { ...empty(), session: this.trail.session, prompt: prompt.trim().slice(0, 300), promptAt: at, updatedAt: at };
      return;
    }
    if (line.type !== "assistant" || !Array.isArray(content)) return;
    for (const c of content) {
      if (c.type !== "tool_use" || !c.input) continue;
      this.trail.updatedAt = at;
      if (c.name === "Read") this.mark(this.inProject(c.input.file_path), "read", at);
      else if (EDITS.has(c.name ?? "")) this.mark(this.inProject(c.input.file_path ?? c.input.notebook_path), "edit", at);
      else if (c.name === "Bash" && typeof c.input.command === "string") {
        for (const path of c.input.command.match(/\/[^\s'"`;&|()<>]+/g) ?? []) this.mark(this.inProject(path), "read", at);
      }
    }
  }
}
