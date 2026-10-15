// What git says about the project: the commits on HEAD, which files a change
// touched, and the diff of one file. A change is either a commit (its hash) or
// the uncommitted work ("worktree": staged, unstaged and untracked, against
// HEAD). Nothing is worked out ahead of time; each call runs git when the page
// asks.
//
// Paths are relative to the project, the folder with sourcemap.json, which may
// sit below the repository root. Files outside it keep their repo-relative path
// with a leading "/" so the page can tell them apart.

import { readFileSync } from "node:fs";
import { join, relative } from "node:path";

export type Commit = {
  hash: string;
  short: string;
  subject: string;
  author: string;
  date: string;
  files: number;
  additions: number;
  deletions: number;
};

export type ChangedFile = {
  path: string;
  oldPath?: string;
  status: "A" | "M" | "D" | "R";
  additions: number;
  deletions: number;
  binary: boolean;
};

export const WORKTREE = "worktree";

export class Repo {
  readonly top: string;
  readonly gitDir: string;
  private prefix: string;

  constructor(readonly project: string) {
    this.top = this.run(["rev-parse", "--show-toplevel"]).trim();
    this.gitDir = this.run(["rev-parse", "--absolute-git-dir"]).trim();
    this.prefix = relative(this.top, project);
  }

  run(args: string[], allowExit: number[] = []): string {
    const result = Bun.spawnSync(["git", "-C", this.top ?? this.project, ...args], { stdout: "pipe", stderr: "pipe" });
    if (result.exitCode !== 0 && !allowExit.includes(result.exitCode)) {
      throw new Error(`git ${args.join(" ")}: ${result.stderr.toString().trim()}`);
    }
    return result.stdout.toString();
  }

  private toProject(path: string): string {
    if (!this.prefix) return path;
    return path.startsWith(this.prefix + "/") ? path.slice(this.prefix.length + 1) : "/" + path;
  }

  private toRepo(path: string): string {
    if (path.startsWith("/")) return path.slice(1);
    return this.prefix ? `${this.prefix}/${path}` : path;
  }

  head(): string | null {
    const out = this.run(["rev-parse", "--verify", "--quiet", "HEAD"], [1]).trim();
    return out || null;
  }

  status(): string {
    return this.run(["status", "--porcelain=v1", "-z", "--untracked-files=all"]);
  }

  commits(skip: number, limit: number): Commit[] {
    if (!this.head()) return [];
    return this.log(["--first-parent", `--skip=${skip}`, `-n${limit}`]);
  }

  commit(hash: string): Commit | null {
    if (!/^[0-9a-f]{4,40}$/.test(hash)) return null;
    return this.log(["-n1", hash], [128])[0] ?? null;
  }

  private log(args: string[], allowExit: number[] = []): Commit[] {
    const out = this.run(["log", "--shortstat", "--format=%x1e%H%x1f%h%x1f%s%x1f%an%x1f%aI", ...args], allowExit);
    return out
      .split("\x1e")
      .filter(Boolean)
      .map((block) => {
        const [header, ...rest] = block.split("\n");
        const [hash, short, subject, author, date] = header.split("\x1f");
        const stat = rest.join(" ");
        const num = (re: RegExp) => Number(stat.match(re)?.[1] ?? 0);
        return {
          hash,
          short,
          subject,
          author,
          date,
          files: num(/(\d+) files? changed/),
          additions: num(/(\d+) insertions?/),
          deletions: num(/(\d+) deletions?/),
        };
      });
  }

  // Merge commits show what they brought in relative to their first parent.
  changes(ref: string): ChangedFile[] {
    const files = ref === WORKTREE ? this.worktreeFiles() : this.commitFiles(ref);
    return files.map((f) => ({
      ...f,
      path: this.toProject(f.path),
      ...(f.oldPath ? { oldPath: this.toProject(f.oldPath) } : {}),
    }));
  }

  private commitFiles(hash: string): ChangedFile[] {
    const base = ["show", "--format=", "-M", "--diff-merges=first-parent", "-z"];
    const statuses = this.parseNameStatus(this.run([...base, "--name-status", hash]));
    const counts = this.parseNumstat(this.run([...base, "--numstat", hash]));
    return statuses.map((s) => ({ ...s, ...(counts.get(s.path) ?? { additions: 0, deletions: 0, binary: false }) }));
  }

  private worktreeFiles(): ChangedFile[] {
    const files = new Map<string, ChangedFile>();
    const parts = this.status().split("\0");
    for (let i = 0; i < parts.length; i++) {
      const entry = parts[i];
      if (entry.length < 4) continue;
      const xy = entry.slice(0, 2);
      const path = entry.slice(3);
      let status: ChangedFile["status"] = "M";
      let oldPath: string | undefined;
      if (xy === "??" || xy.includes("A")) status = "A";
      else if (xy.includes("D")) status = "D";
      else if (xy.includes("R")) {
        status = "R";
        oldPath = parts[++i];
      }
      files.set(path, { path, ...(oldPath ? { oldPath } : {}), status, additions: 0, deletions: 0, binary: false });
    }
    if (this.head()) {
      for (const [path, count] of this.parseNumstat(this.run(["diff", "HEAD", "-M", "--numstat", "-z"]))) {
        const file = files.get(path);
        if (file) Object.assign(file, count);
      }
    }
    for (const file of files.values()) {
      if (file.status !== "A" || file.additions) continue;
      try {
        const text = readFileSync(join(this.top, file.path), "utf8");
        if (text.includes("\0")) file.binary = true;
        else file.additions = text.split("\n").length - (text.endsWith("\n") ? 1 : 0);
      } catch {}
    }
    return [...files.values()];
  }

  private parseNameStatus(out: string): Omit<ChangedFile, "additions" | "deletions" | "binary">[] {
    const parts = out.split("\0").filter(Boolean);
    const found = [];
    for (let i = 0; i < parts.length; i++) {
      const code = parts[i][0];
      if (code === "R" || code === "C") {
        found.push({ status: "R" as const, oldPath: parts[i + 1], path: parts[i + 2] });
        i += 2;
      } else {
        const status = code === "A" || code === "D" ? code : "M";
        found.push({ status, path: parts[++i] });
      }
    }
    return found;
  }

  // -z numstat: "add\tdel\tpath\0", or for a rename "add\tdel\t\0old\0new\0".
  private parseNumstat(out: string): Map<string, { additions: number; deletions: number; binary: boolean }> {
    const counts = new Map();
    const parts = out.split("\0");
    for (let i = 0; i < parts.length; i++) {
      const m = parts[i].match(/^(\d+|-)\t(\d+|-)\t(.*)$/s);
      if (!m) continue;
      let path = m[3];
      if (!path) {
        path = parts[i + 2];
        i += 2;
      }
      const binary = m[1] === "-";
      counts.set(path, { additions: binary ? 0 : Number(m[1]), deletions: binary ? 0 : Number(m[2]), binary });
    }
    return counts;
  }

  diff(ref: string, path: string, oldPath?: string): string {
    const paths = [this.toRepo(path), ...(oldPath ? [this.toRepo(oldPath)] : [])];
    if (ref !== WORKTREE) {
      return this.run(["show", "--format=", "-M", "--diff-merges=first-parent", ref, "--", ...paths]);
    }
    const tracked = this.head() ? this.run(["diff", "HEAD", "-M", "--", ...paths]) : "";
    if (tracked) return tracked;
    // Untracked: git diff only compares it with nothing outside the index.
    return this.run(["diff", "--no-index", "--", "/dev/null", paths[0]], [1]);
  }
}
