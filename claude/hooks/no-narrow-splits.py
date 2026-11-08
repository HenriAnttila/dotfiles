#!/usr/bin/env python3
"""PreToolUse hook (Bash): refuse commands that split Henri's tmux pane directly.

Everything that goes beside the conversation must open through
~/.tmux/scripts/open-beside.sh, which splits only while the pane's row has one
or two panes side by side and opens a new window (tab) once it has three, so
nothing ends up a narrow fourth column. Refused here:
  - `tmux split-window` / `tmux splitw`
  - `terminal-browser open` outside open-beside.sh or the tmux skill's popup.py
    (with --split, or without a TTY as in Claude's Bash, it splits by itself)
"""
import json
import re
import sys

cmd = (json.load(sys.stdin).get("tool_input") or {}).get("command") or ""
segments = re.split(r"[|;&\n]", cmd)

reason = None
if any(re.search(r"\btmux\b.*\b(split-window|splitw)\b", s) for s in segments):
    reason = "tmux split-window"
elif re.search(r"\bterminal-browser\s+open\b", cmd) and (
        "--split" in cmd or not re.search(r"open-beside\.sh|popup\.py", cmd)):
    reason = "terminal-browser opening its own split"

if reason:
    print(json.dumps({"hookSpecificOutput": {
        "hookEventName": "PreToolUse",
        "permissionDecision": "deny",
        "permissionDecisionReason":
            f"Blocked {reason}: Henri doesn't want narrow panes. Open it with "
            "~/.tmux/scripts/open-beside.sh -d -n <name> \"$TMUX_PANE\" -- <command> "
            "(a split while the row has one or two panes side by side, a new tab once it has three), "
            "or as a popup with ~/.claude/skills/tmux/scripts/popup.py.",
    }}))
