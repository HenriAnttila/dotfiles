#!/bin/bash

# Symlink configs
ln -sf ~/dotfiles/nvim ~/.config/nvim
ln -sf ~/dotfiles/yazi ~/.config/yazi

# lazygit (config path differs between macOS and Linux)
if [[ "$OSTYPE" == "darwin"* ]]; then
  LAZYGIT_DIR="$HOME/Library/Application Support/lazygit"
else
  LAZYGIT_DIR="$HOME/.config/lazygit"
fi
mkdir -p "$LAZYGIT_DIR"
ln -sf ~/dotfiles/lazygit.yml "$LAZYGIT_DIR/config.yml"

# Add other symlinks as needed
# ln -sf ~/dotfiles/bashrc ~/.bashrc
# ln -sf ~/dotfiles/tmux.conf ~/.tmux.conf

echo "Dotfiles installed!"
