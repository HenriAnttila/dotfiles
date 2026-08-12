#!/bin/bash

# Symlink configs. -n is required for directories: without it a re-run follows
# the existing symlink and creates a self-referential link *inside* the target.
ln -sfn ~/dotfiles/nvim ~/.config/nvim
ln -sfn ~/dotfiles/yazi ~/.config/yazi
ln -sfn ~/dotfiles/ghostty ~/.config/ghostty

# lazygit (config path differs between macOS and Linux)
if [[ "$OSTYPE" == "darwin"* ]]; then
  LAZYGIT_DIR="$HOME/Library/Application Support/lazygit"
else
  LAZYGIT_DIR="$HOME/.config/lazygit"
fi
mkdir -p "$LAZYGIT_DIR"
ln -sf ~/dotfiles/lazygit.yml "$LAZYGIT_DIR/config.yml"

# gh-dash (GitHub CLI dashboard) config
mkdir -p ~/.config/gh-dash
ln -sf ~/dotfiles/gh-dash/config.yml ~/.config/gh-dash/config.yml

# tmux helper scripts (referenced from tmux.conf status-right)
mkdir -p ~/.tmux/scripts
ln -sf ~/dotfiles/tmux/scripts/git-branch.sh ~/.tmux/scripts/git-branch.sh

# tmux-window-name plugin needs libtmux. Its launcher checks bare `python`
# (which may be anaconda/another interpreter), while the rename script uses
# `python3` via env. Install into both so the check and the script both pass.
# Homebrew's python is externally managed (PEP 668), hence --break-system-packages.
python3 -m pip install --user --break-system-packages libtmux 2>/dev/null \
  || python3 -m pip install --user libtmux
command -v python >/dev/null && python -m pip install libtmux 2>/dev/null || true

# Claude Code global instructions
mkdir -p ~/.claude
ln -sf ~/dotfiles/.claude/CLAUDE.md ~/.claude/CLAUDE.md

# Claude Code personal skills. Symlinked per-skill, not as a whole directory:
# ~/.claude/skills also holds skills installed from plugin marketplaces, and a
# directory-level symlink would hide them. Third-party skills belong in
# settings.json under enabledPlugins, not here.
mkdir -p ~/.claude/skills
for skill in ~/dotfiles/claude/skills/*/; do
  ln -sfn "$skill" ~/.claude/skills/"$(basename "$skill")"
done

# Add other symlinks as needed
# ln -sf ~/dotfiles/bashrc ~/.bashrc
# ln -sf ~/dotfiles/tmux.conf ~/.tmux.conf

echo "Dotfiles installed!"
