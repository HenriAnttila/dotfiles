// The page's colours and font, read from the terminal so codegraph looks like
// the Ghostty it opens in.
//
// Ghostty's config gives the font and the fallback palette; theme.generated,
// which the theme picker (tmux/scripts/theme-apply.sh) rewrites on every pick,
// overrides the colours, the same way Ghostty includes it last. The accent is
// tmux's @accent, the one the status bar uses. muted and faint are mixed from
// the background and foreground the way theme-apply.sh mixes them for tmux,
// muted a little brighter so the page's secondary text stays readable.
//
// The page loads this as /theme.css on top of style.css, whose own values are
// the fallback when a file or tmux is missing. The server watches the Ghostty
// folder, so a theme pick reaches an open page without a reload.

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const GHOSTTY_DIR = join(homedir(), ".config", "ghostty");
const FILES = [join(GHOSTTY_DIR, "config"), join(GHOSTTY_DIR, "theme.generated")];

const hex = (value: string | undefined) => {
  const m = value?.match(/^#?([0-9a-fA-F]{6})$/);
  return m ? `#${m[1].toLowerCase()}` : null;
};

function mix(a: string, b: string, percent: number): string {
  const channel = (c: string, i: number) => parseInt(c.slice(1 + i * 2, 3 + i * 2), 16);
  const out = [0, 1, 2].map((i) => Math.round((channel(a, i) * (100 - percent) + channel(b, i) * percent) / 100));
  return `#${out.map((n) => n.toString(16).padStart(2, "0")).join("")}`;
}

function ghostty() {
  const values: Record<string, string> = {};
  const palette: string[] = [];
  for (const file of FILES) {
    if (!existsSync(file)) continue;
    for (const line of readFileSync(file, "utf8").split("\n")) {
      const m = line.match(/^\s*([a-z-]+)\s*=\s*(.+?)\s*$/);
      if (!m) continue;
      const value = m[2].replace(/^"(.*)"$/, "$1");
      const entry = m[1] === "palette" ? value.match(/^(\d+)\s*=\s*(#?[0-9a-fA-F]{6})$/) : null;
      if (entry) palette[Number(entry[1])] = hex(entry[2])!;
      else if (m[1] !== "palette") values[m[1]] = value;
    }
  }
  return { values, palette };
}

function tmuxAccent(): string | null {
  const result = Bun.spawnSync(["tmux", "show", "-gv", "@accent"], { stdout: "pipe", stderr: "ignore" });
  return result.exitCode === 0 ? hex(result.stdout.toString().trim()) : null;
}

export function themeCss(): string {
  const { values, palette } = ghostty();
  const bg = hex(values.background);
  const fg = hex(values.foreground);
  const vars: Record<string, string | null | undefined> = {};

  if (bg && fg) {
    Object.assign(vars, {
      bg,
      surface: bg,
      text: fg,
      raised: hex(values["selection-background"]) ?? mix(bg, fg, 12),
      line: mix(bg, fg, 18),
      muted: mix(bg, fg, 60),
      faint: mix(bg, fg, 30),
      require: mix(bg, fg, 40),
    });
  }
  Object.assign(vars, {
    accent: tmuxAccent() ?? palette[4],
    added: palette[2],
    modified: palette[3],
    deleted: palette[1],
    renamed: palette[4],
    starts: palette[5],
    remote: palette[6],
    "syntax-keyword": palette[5],
    "syntax-string": palette[2],
    "syntax-number": palette[3],
    "syntax-function": palette[4],
    "syntax-builtin": palette[6],
    "syntax-property": palette[1],
  });

  const font = values["font-family"];
  const lines = Object.entries(vars)
    .filter(([, v]) => v)
    .map(([k, v]) => `  --${k}: ${v};`);
  if (font && !/[;{}]/.test(font)) lines.push(`  --mono: "${font}", ui-monospace, "SF Mono", Menlo, monospace;`);
  return `:root {\n${lines.join("\n")}\n}\n`;
}

if (import.meta.main) console.log(themeCss());
