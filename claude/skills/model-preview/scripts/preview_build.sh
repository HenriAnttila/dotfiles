#!/bin/sh
# preview_build.sh BLEND [SCRIPT.py ...] [ARG ...]
#
# A preview .glb of a .blend, optionally after running scripts on it, meant
# not to save the .blend: --no-save is passed to the scripts and the file's
# modification time is checked afterwards. Writes ~/.cache/meshview/<name>.glb
# (the .blend's own units and frame) and prints its path. Blender's output goes
# to ~/.cache/meshview/<name>.log.
set -eu

[ $# -ge 1 ] || { echo "usage: preview_build.sh BLEND [SCRIPT.py ...] [ARG ...]" >&2; exit 2; }
blend="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
shift
[ -f "$blend" ] || { echo "no such file: $blend" >&2; exit 1; }
blender=/Applications/Blender.app/Contents/MacOS/Blender
here="$(cd "$(dirname "$0")" && pwd)"
name="$(basename "$blend" .blend)"
out="$HOME/.cache/meshview/$name.glb"
log="$HOME/.cache/meshview/$name.log"
mkdir -p "$HOME/.cache/meshview"

# scripts as absolute paths, so they run the same from any directory
n=$#
for a in "$@"; do
  case "$a" in
    *.py) a="$(cd "$(dirname "$a")" && pwd)/$(basename "$a")" ;;
  esac
  set -- "$@" "$a"
done
shift "$n"

before="$(stat -f %m "$blend")"
tmp="$out.tmp.glb"
if ! "$blender" -b "$blend" --python "$here/preview_export.py" -- "$tmp" "$@" >"$log" 2>&1; then
  tail -20 "$log" >&2
  exit 1
fi
[ "$(stat -f %m "$blend")" = "$before" ] || { echo "WARNING: $blend changed during the preview build" >&2; }
grep -q "PREVIEW wrote" "$log" || { tail -20 "$log" >&2; exit 1; }
# where the preview came from, for meshview: the project's placed shots and the unit
place="$(dirname "$blend")/observations/place"
[ -d "$place" ] || place=""
printf '{"source": "%s", "refs": "%s", "unit_m": 1.0}\n' "$blend" "$place" > "$out.meshview.json"
mv "$tmp" "$out"  # one rename, so the watching viewer never reads a half-written file
echo "$out"
