#!/usr/bin/env bash
# Apply an nvim colorscheme to the whole terminal: Ghostty, tmux and every
# running nvim. The nvim colorscheme list is the theme list -- there is no
# separate theme format. nvim's own last_colorscheme.txt (see
# nvim/lua/plugins/theme.lua) is the record of the current theme, so picking
# with `:colorscheme` in nvim and picking here end up in the same place.
#
#   theme-apply.sh NAME            apply for good (all of the below)
#   theme-apply.sh --preview NAME  Ghostty colors live (OSC) + tmux, nothing saved
#   theme-apply.sh --tmux [NAME]   tmux colors only (tmux.conf runs this at
#                                  startup with the saved theme)
#   theme-apply.sh --list          print the theme names, one per line
#
# Colors come from a cache built by theme-extract.lua in headless nvim; it is
# rebuilt whenever the nvim theme plugins or lockfile are newer than it.
#
# "Apply for good" means:
#   1. tmux: @accent/@accent_dim plus the status, message, mode and border
#      styles (tmux.conf's SATURN values are only the fallback).
#   2. Ghostty, live: OSC 10/11/12/17/4 written straight to every tmux
#      client's tty, so the change is instant.
#   3. Ghostty, persisted: ghostty/theme.generated (included at the end of the
#      Ghostty config) is rewritten and Ghostty reloads it over AppleScript.
#      Without this, nvim's OSC 111 (reset bg) on launch would snap the
#      background back to the old theme.
#   4. nvim: last_colorscheme.txt for new instances, `:colorscheme` sent to
#      running ones -- whose ColorScheme autocmd then pushes the same accent
#      and palette, as it always has.

set -u

data="${XDG_DATA_HOME:-$HOME/.local/share}/nvim"
last="$data/last_colorscheme.txt"
cache_dir="${XDG_CACHE_HOME:-$HOME/.cache}/tmux-theme"
cache="$cache_dir/themes.tsv"
nvim_conf="${XDG_CONFIG_HOME:-$HOME/.config}/nvim"
ghostty_theme="${XDG_CONFIG_HOME:-$HOME/.config}/ghostty/theme.generated"
here="$(dirname "$(readlink -f "$0")")"

build_cache() {
  if [ -s "$cache" ] && [ -z "$(find -L "$nvim_conf/lazy-lock.json" "$nvim_conf/lua/plugins/theme.lua" \
      "$nvim_conf/colors" -newer "$cache" 2>/dev/null | head -1)" ]; then
    return
  fi
  mkdir -p "$cache_dir"
  # Loading each scheme fires theme.lua's ColorScheme autocmd, which records
  # it as the last colorscheme. Put the real one back afterwards.
  local saved
  saved="$(cat "$last" 2>/dev/null)"
  (cd "$cache_dir" && nvim --headless --cmd "let g:theme_out = '$cache.tmp'" \
    -c "luafile $here/theme-extract.lua" -c 'qa!' >/dev/null 2>&1)
  [ -n "$saved" ] && printf '%s\n' "$saved" > "$last"
  [ -s "$cache.tmp" ] && mv "$cache.tmp" "$cache"
}

# Blend two #rrggbb colors: mix A B T -> A*(1-T) + B*T, T in hundredths.
mix() {
  local a="${1#\#}" b="${2#\#}" t="$3" out="#" i x y
  for i in 0 2 4; do
    x=$((16#${a:i:2})); y=$((16#${b:i:2}))
    out+="$(printf '%02x' $(((x * (100 - t) + y * t + 50) / 100)))"
  done
  printf '%s' "$out"
}

# Scale a color's brightness, same as set_accent() in nvim's autocmds.lua.
dim() {
  mix "$1" "#000000" 40
}

load() {
  build_cache
  row="$(awk -F'\t' -v n="$1" '$1 == n' "$cache")"
  [ -n "$row" ] || return 1
  IFS=$'\t' read -r name bg fg cursor sel accent c0 c1 c2 c3 c4 c5 c6 c7 c8 c9 c10 c11 c12 c13 c14 c15 <<< "$row"
  pal=("$c0" "$c1" "$c2" "$c3" "$c4" "$c5" "$c6" "$c7" "$c8" "$c9" "$c10" "$c11" "$c12" "$c13" "$c14" "$c15")
  # Schemes that set no terminal colors (flexoki, shale, ...) get SATURN's,
  # the Ghostty config's own palette -- otherwise they'd keep whatever the
  # previous theme left behind.
  local saturn=("#211617" "#c47164" "#9bb18b" "#ceb37e" "#83a3b9" "#ba97ae" "#83b9b0" "#acc1bb"
    "#778483" "#d58c81" "#afc69f" "#ddc698" "#99b7cc" "#cdacc2" "#99ccc3" "#e9efe7")
  local i
  for i in "${!pal[@]}"; do
    [ "${pal[i]}" = - ] && pal[i]="${saturn[i]}"
  done
  c3="${pal[3]}"
  [ "$fg" = - ] && fg="#d4e1db"
  [ "$accent" = - ] && accent="#1688f0"  # nvim's fallback too
  [ "$sel" = - ] && sel="$(mix "$bg" "$fg" 20)"
  return 0
}

apply_tmux() {
  local muted faint mode_fg
  muted="$(mix "$bg" "$fg" 50)"
  faint="$(mix "$bg" "$fg" 30)"
  mode_fg="$c3"
  tmux set -g @accent "$accent" \; set -g @accent_dim "$(dim "$accent")" \
    \; set -g @fg "$fg" \; set -g @bg "$bg" \; set -g @muted "$muted" \
    \; set -g @faint "$faint" \; set -g @sel "$sel" \
    \; set -g status-style "bg=default,fg=$fg" \
    \; set -g mode-style "fg=$mode_fg,bg=$sel" \
    \; set -g message-style "fg=$fg,bg=$sel" \
    \; set -g message-command-style "fg=$fg,bg=$sel" \
    \; set -g pane-border-style "fg=$sel" \
    \; set -g clock-mode-colour "$accent" \
    \; refresh-client -S
}

apply_ghostty_live() {
  local seq i tty
  seq="$(printf '\033]10;%s\033\\\033]11;%s\033\\\033]12;%s\033\\\033]17;%s\033\\' "$fg" "$bg" "$cursor" "$sel")"
  for i in "${!pal[@]}"; do
    seq+="$(printf '\033]4;%d;%s\033\\' "$i" "${pal[i]}")"
  done
  for tty in $(tmux list-clients -F '#{client_tty}'); do
    printf '%s' "$seq" > "$tty" 2>/dev/null
  done
}

apply_ghostty_config() {
  local i
  {
    echo "# Generated by tmux/scripts/theme-apply.sh from nvim colorscheme '$name'."
    echo "# Rewritten on every theme pick; edit the colorscheme, not this file."
    echo "background = $bg"
    echo "foreground = $fg"
    echo "cursor-color = $cursor"
    echo "cursor-text = $bg"
    echo "selection-background = $sel"
    echo "selection-foreground = $fg"
    for i in "${!pal[@]}"; do
      echo "palette = $i=${pal[i]}"
    done
  } > "$ghostty_theme"
  pgrep -xq ghostty && osascript -e 'tell application "Ghostty" to if (count windows) > 0 then perform action "reload_config" on terminal 1 of tab 1 of window 1' >/dev/null 2>&1
}

apply_nvim() {
  local sock
  printf '%s\n' "$name" > "$last"
  find "${TMPDIR:-/tmp/}nvim.$USER" -type s 2>/dev/null | while read -r sock; do
    nvim --server "$sock" --remote-expr "execute('colorscheme $name')" >/dev/null 2>&1 &
  done
  wait
}

case "${1:-}" in
  --list)
    build_cache
    cut -f1 "$cache"
    ;;
  --preview)
    load "${2:-}" || exit 1
    apply_tmux
    apply_ghostty_live
    ;;
  --tmux)
    load "${2:-$(cat "$last" 2>/dev/null)}" || exit 0
    apply_tmux
    ;;
  -*|"")
    sed -n '2,13s/^# \{0,1\}//p' "$0" >&2
    exit 2
    ;;
  *)
    load "$1" || { echo "unknown theme: $1" >&2; exit 1; }
    apply_tmux
    apply_ghostty_live
    apply_ghostty_config
    apply_nvim
    ;;
esac
