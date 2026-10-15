#!/usr/bin/env python3
# Open a command in a tmux popup over Claude's pane, without waiting for it.
# Usage: popup.py [-w 85%] [-h 85%] [-T title] [-d dir] -- command [arg ...]
#        popup.py --inside <cell WxH> command [arg ...]   (inside the popup)
#
# Two stages. Outside the popup it reads the cell size in pixels from tmux and
# starts `tmux display-popup` in the background: from a shell that command
# blocks until the popup closes, and Claude's Bash would block with it. Inside
# the popup it fills in the pixel size of the terminal, then becomes the
# command.
#
# The pixel size is why this script exists. tmux tells a program in a pane how
# big the pane is in pixels, but leaves a popup's at 0 and does not answer
# pixel queries from it either, so terminal-browser guesses and renders the
# page at the wrong scale. Cols x cell width and rows x cell height is what a
# pane of the same size would report.
#
# The command is passed to tmux as separate arguments, so it runs without a
# shell: no quoting for fish, the default-shell that would run it otherwise.
#
# Untested: resizing the terminal while a popup is open. tmux may reset the
# pixel size to 0 then.

import fcntl
import os
import struct
import subprocess
import sys
import termios

if sys.argv[1:2] == ["--inside"]:
    cell_w, cell_h = (int(n) for n in sys.argv[2].split("x"))
    command = sys.argv[3:]
    rows, cols, _, _ = struct.unpack("HHHH", fcntl.ioctl(0, termios.TIOCGWINSZ, bytes(8)))
    fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, cols * cell_w, rows * cell_h))
    os.execvp(command[0], command)

pane = os.environ.get("TMUX_PANE")
if not pane:
    sys.exit("popup.py: not running inside tmux")

options = {"-w": "85%", "-h": "85%", "-T": None, "-d": os.getcwd()}
args = sys.argv[1:]
while args and args[0] != "--":
    if args[0] not in options or len(args) < 2:
        sys.exit(f"popup.py: unknown option {args[0]}")
    options[args[0]] = args[1]
    args = args[2:]
command = args[1:]
if not command:
    sys.exit("usage: popup.py [-w 85%] [-h 85%] [-T title] [-d dir] -- command [arg ...]")

cell = subprocess.check_output(
    ["tmux", "display", "-p", "-t", pane, "#{client_cell_width}x#{client_cell_height}"], text=True
).strip()

popup = ["tmux", "display-popup", "-E", "-t", pane, "-w", options["-w"], "-h", options["-h"], "-d", options["-d"]]
if options["-T"]:
    popup += ["-T", f" {options['-T']} "]
popup += ["python3", "-I", os.path.realpath(__file__), "--inside", cell, *command]

subprocess.Popen(
    popup,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.DEVNULL,
    stderr=subprocess.DEVNULL,
    start_new_session=True,
)
