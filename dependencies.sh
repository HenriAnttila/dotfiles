#!/bin/bash

echo "Installing dependencies for LazyVim..."

# Detect OS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
  # Ubuntu/Debian
  if command -v apt &>/dev/null; then
    sudo apt update
    sudo apt install -y \
      git \
      curl \
      build-essential \
      ripgrep \
      fd-find \
      fzf \
      jq \
      python3 \
      python3-pip

    # Install Node.js (via NodeSource)
    echo "Installing Node.js..."
    curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
    sudo apt install -y nodejs

    # Install GitHub CLI (gh) from the official apt repo
    if ! command -v gh &>/dev/null; then
      echo "Installing GitHub CLI..."
      (type -p wget >/dev/null || sudo apt install -y wget)
      sudo mkdir -p -m 755 /etc/apt/keyrings
      wget -qO- https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg >/dev/null
      sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
      sudo apt update
      sudo apt install -y gh
    fi

    # Install lazygit
    echo "Installing lazygit..."
    LAZYGIT_VERSION=$(curl -s "https://api.github.com/repos/jesseduffield/lazygit/releases/latest" | grep -Po '"tag_name": "v\K[^"]*')
    curl -Lo lazygit.tar.gz "https://github.com/jesseduffield/lazygit/releases/latest/download/lazygit_${LAZYGIT_VERSION}_Linux_x86_64.tar.gz"
    tar xf lazygit.tar.gz lazygit
    sudo install lazygit /usr/local/bin
    rm lazygit lazygit.tar.gz

    # Install newer Neovim (distro version is usually too old)
    echo "Installing Neovim..."
    sudo add-apt-repository ppa:neovim-ppa/unstable -y
    sudo apt update
    sudo apt install -y neovim

    echo "✓ Dependencies installed!"

  # Arch / Arch-based distributions (Manjaro, EndeavourOS, etc.)
  elif command -v pacman &>/dev/null; then
    sudo pacman -Syu --noconfirm
    sudo pacman -S --noconfirm \
      git \
      curl \
      base-devel \
      ripgrep \
      fzf \
      jq \
      fd \
      python \
      python-pip \
      neovim \
      nodejs \
      npm \
      lazygit \
      github-cli

    echo "✓ Dependencies installed!"

  # RHEL/Fedora-based distributions
  elif command -v dnf &>/dev/null; then
    sudo dnf install -y \
      git \
      curl \
      gcc \
      gcc-c++ \
      ripgrep \
      fd-find \
      fzf \
      jq \
      python3 \
      python3-pip

    # Install Node.js
    echo "Installing Node.js..."
    curl -fsSL https://rpm.nodesource.com/setup_lts.x | sudo bash -
    sudo dnf install -y nodejs

    # Install lazygit
    echo "Installing lazygit..."
    sudo dnf copr enable atim/lazygit -y
    sudo dnf install -y lazygit

    # Install GitHub CLI (gh)
    echo "Installing GitHub CLI..."
    sudo dnf install -y 'dnf-command(config-manager)'
    sudo dnf config-manager --add-repo https://cli.github.com/packages/rpm/gh-cli.repo
    sudo dnf install -y gh

    echo "✓ Dependencies installed!"
  fi

elif [[ "$OSTYPE" == "darwin"* ]]; then
  # macOS
  if ! command -v brew &>/dev/null; then
    echo "Homebrew not found. Install from https://brew.sh"
    exit 1
  fi

  brew install \
    git \
    curl \
    ripgrep \
    fd \
    fzf \
    jq \
    lazygit \
    neovim \
    node \
    python \
    gh
  echo "✓ Dependencies installed!"
fi

# Install gh-dash (GitHub CLI dashboard extension) — cross-platform via gh
if command -v gh &>/dev/null; then
  echo "Installing gh-dash..."
  gh extension install dlvhdr/gh-dash 2>/dev/null \
    || gh extension upgrade dlvhdr/gh-dash 2>/dev/null \
    || true
fi

echo ""
echo "Verifying installations..."
nvim --version | head -n 1
nvim --version | grep -i luajit && echo "✓ LuaJIT support detected" || echo "⚠ Warning: LuaJIT not detected"
node --version 2>/dev/null && echo "✓ Node.js installed" || echo "⚠ Node.js not found"
python3 --version && echo "✓ Python installed" || echo "⚠ Python not found"
lazygit --version 2>/dev/null && echo "✓ lazygit installed" || echo "⚠ lazygit not found"
gh --version 2>/dev/null | head -n 1 && echo "✓ gh installed" || echo "⚠ gh not found"
gh dash --version 2>/dev/null | tail -n 1 && echo "✓ gh-dash installed" || echo "⚠ gh-dash not found"
echo ""
echo "Run ./install.sh to set up your config!"

