#!/bin/bash

# Symlink configs
ln -sf ~/dotfiles/nvim ~/.config/nvim
ln -sf ~/dotfiles/yazi ~/.config/yazi
ln -sf ~/dotfiles/ghostty ~/.config/ghostty

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

# Add other symlinks as needed
# ln -sf ~/dotfiles/bashrc ~/.bashrc
# ln -sf ~/dotfiles/tmux.conf ~/.tmux.conf

echo "Dotfiles installed!"
