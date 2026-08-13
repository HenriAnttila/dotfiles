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

# Claude Code personal skills — only skills written here, never downloaded ones.
# Third-party skills are installed from a marketplace instead (see
# enabledPlugins in ~/.claude/settings.json) so they stay versioned and
# updatable via `claude plugin update`.
#
# Symlinked per-skill, not as a whole directory: ~/.claude/skills also holds
# marketplace-installed skills, and a directory-level symlink would hide them.
mkdir -p ~/.claude/skills
find ~/.claude/skills -maxdepth 1 -type l ! -exec test -e {} \; -delete  # prune dead links
for skill in ~/dotfiles/claude/skills/*/; do
  ln -sfn "$skill" ~/.claude/skills/"$(basename "$skill")"
done

# zsh aliases. ~/.zshrc itself is not tracked (it holds machine-generated nvm,
# conda, and bun bootstrap), so hook the tracked aliases in with a source line.
ZSH_SOURCE_LINE='[ -f "$HOME/dotfiles/zsh/aliases.zsh" ] && source "$HOME/dotfiles/zsh/aliases.zsh"'
if ! grep -qF 'dotfiles/zsh/aliases.zsh' ~/.zshrc 2>/dev/null; then
  echo "$ZSH_SOURCE_LINE" >>~/.zshrc
fi

# Add other symlinks as needed
# ln -sf ~/dotfiles/bashrc ~/.bashrc
# ln -sf ~/dotfiles/tmux.conf ~/.tmux.conf

echo "Dotfiles installed!"
