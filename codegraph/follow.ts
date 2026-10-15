// Following Claude while it works, from the sessions' transcripts: what each
// session read and edited in this project since its last prompt.
//
// Claude Code appends every message to ~/.claude/projects/<dir>/<session>.jsonl
// as it happens, tool calls included, so the transcripts are read rather than
// asking hooks for anything. <dir> is the folder the session started in, with
// every character that isn't a letter or digit turned into "-".
//
// The sessions offered are the ones written to in the last day, out of those
// started in the project and those hook.ts saw changing it (sessions.json),
// which covers a session started somewhere else that works on this project by
// path. The page picks which one to show; it starts on the most recent and
// stays there until you pick another, so several sessions working at once
// never make it jump. Each session's trail is kept separately, so two pages
// can follow two sessions.
//
// A prompt you type (a "user" line from a human, not a tool result or a system
// note) starts a new trail. Read marks a file read; Edit, MultiEdit, Write and
// NotebookEdit mark it edited, the moment the call is made; an absolute path in
// a Bash command marks a file read. Files outside the project are left out.
//
// A transcript is read from where it was last read up to its end each time it
// is asked for; the first time, from its last few megabytes, which is plenty to
// reach its last prompt.

import { closeSync, existsSync, openSync, readdirSync, readSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative } from "node:path";
import type { Sessions, Store } from "./store.ts";

export const PROJECTS = join(homedir(), ".claude", "projects");
const slug = (dir: string) => dir.replace(/[^a-zA-Z0-9]/g, "-");
const WINDOW = 8 * 1024 * 1024;
const RECENT_MS = 24 * 60 * 60 * 1000;
const EDITS = new Set(["Edit", "MultiEdit", "Write", "NotebookEdit"]);

export type Trail = {
  session: string;
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

export type SessionInfo = {
  id: string;
  startedIn: string;
  prompt: string | null;
  updatedAt: string | null;
  writtenAt: number;
  edits: number;
  reads: number;
};

type Line = {
  type?: string;
  isMeta?: boolean;
  origin?: { kind?: string };
  timestamp?: string;
  message?: { content?: string | { type: string; text?: string; name?: string; input?: Record<string, unknown> }[] };
};

class Transcript {
  private offset: number;
  private rest = "";
  private skip: boolean;
  private reads = new Set<string>();
  private edits = new Set<string>();
  trail: Trail;

  constructor(
    readonly file: string,
    private project: string,
  ) {
    const size = statSync(file).size;
    this.offset = Math.max(0, size - WINDOW);
    this.skip = this.offset > 0;
    this.trail = Transcript.empty(basename(file, ".jsonl"));
  }

  static empty(session: string): Trail {
    return { session, prompt: null, promptAt: null, reads: [], edits: [], latest: null, lastEdit: null, updatedAt: null };
  }

  update() {
    const size = statSync(this.file).size;
    if (size < this.offset) this.offset = 0;
    if (size === this.offset) return;
    const fd = openSync(this.file, "r");
    const buffer = Buffer.alloc(size - this.offset);
    readSync(fd, buffer, 0, buffer.length, this.offset);
    closeSync(fd);
    this.offset = size;
    const lines = (this.rest + buffer.toString("utf8")).split("\n");
    this.rest = lines.pop() ?? "";
    if (this.skip) lines.shift();
    this.skip = false;
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
      this.trail = { ...Transcript.empty(this.trail.session), prompt: prompt.trim().slice(0, 300), promptAt: at, updatedAt: at };
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

export class Follower {
  private transcripts = new Map<string, Transcript>();

  constructor(
    private project: string,
    private store: Store,
  ) {}

  // Every transcript that could be working on this project, with where its
  // session started.
  private candidates(): Map<string, string> {
    const found = new Map<string, string>();
    const own = join(PROJECTS, slug(this.project));
    if (existsSync(own)) for (const f of readdirSync(own)) if (f.endsWith(".jsonl")) found.set(join(own, f), this.project);
    const sessions = this.store.read<Sessions>("sessions.json", { head: null, sessions: {}, files: {} }).sessions;
    for (const [id, s] of Object.entries(sessions)) {
      const file = join(PROJECTS, slug(s.cwd), `${id}.jsonl`);
      if (existsSync(file)) found.set(file, s.cwd);
    }
    return found;
  }

  concerns(path: string): boolean {
    return path.endsWith(".jsonl") && this.candidates().has(path);
  }

  // The sessions written to in the last day, newest first, each brought up to date.
  sessions(): SessionInfo[] {
    const now = Date.now();
    const list: SessionInfo[] = [];
    for (const [file, cwd] of this.candidates()) {
      const writtenAt = statSync(file).mtimeMs;
      if (now - writtenAt > RECENT_MS) continue;
      let transcript = this.transcripts.get(file);
      if (!transcript) this.transcripts.set(file, (transcript = new Transcript(file, this.project)));
      transcript.update();
      const t = transcript.trail;
      list.push({ id: t.session, startedIn: cwd, prompt: t.prompt, updatedAt: t.updatedAt, writtenAt, edits: t.edits.length, reads: t.reads.length });
    }
    return list.sort((a, b) => b.writtenAt - a.writtenAt);
  }

  // The sessions on offer and the trail of the one asked for. Without one (or
  // when it's no longer on offer): the most recent session that has read or
  // edited something here since its prompt, else the most recent of all.
  view(session: string | null): { sessions: SessionInfo[]; trail: Trail | null } {
    const sessions = this.sessions();
    const chosen = sessions.find((s) => s.id === session) ?? sessions.find((s) => s.edits + s.reads > 0) ?? sessions[0];
    const transcript = chosen && [...this.transcripts.values()].find((t) => t.trail.session === chosen.id);
    return { sessions, trail: transcript ? transcript.trail : null };
  }
}
