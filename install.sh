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

# tmux helper scripts (referenced from tmux.conf status-right)
mkdir -p ~/.tmux/scripts
ln -sf ~/dotfiles/tmux/scripts/git-branch.sh ~/.tmux/scripts/git-branch.sh

# tmux-window-name plugin needs libtmux. Homebrew's python is externally
# managed (PEP 668), so install into the user site with --break-system-packages.
python3 -m pip install --user --break-system-packages libtmux

# Add other symlinks as needed
# ln -sf ~/dotfiles/bashrc ~/.bashrc
# ln -sf ~/dotfiles/tmux.conf ~/.tmux.conf

echo "Dotfiles installed!"
