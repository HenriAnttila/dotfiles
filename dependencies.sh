#!/bin/bash

echo "Installing dependencies for LazyVim..."

# Detect OS
if [[ "$OSTYPE" == "linux-gnu"* ]]; then
    # Ubuntu/Debian
    if command -v apt &> /dev/null; then
        sudo apt update
        sudo apt install -y \
            git \
            curl \
            build-essential \
            ripgrep \
            fd-find \
            fzf \
            lazygit \
            nodejs \
            npm \
            python3 \
            python3-pip
        
        # Install newer Neovim (distro version is usually too old)
        echo "Installing Neovim..."
        sudo add-apt-repository ppa:neovim-ppa/unstable -y
        sudo apt update
        sudo apt install -y neovim
        
        echo "✓ Dependencies installed!"
        
    # RHEL/Fedora
    elif command -v dnf &> /dev/null; then
        sudo dnf install -y \
            git \
            curl \
            gcc \
            gcc-c++ \
            ripgrep \
            fd-find \
            fzf \
            lazygit \
            neovim \
            nodejs \
            npm \
            python3 \
            python3-pip
        echo "✓ Dependencies installed!"
    fi
    
elif [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS
    if ! command -v brew &> /dev/null; then
        echo "Homebrew not found. Install from https://brew.sh"
        exit 1
    fi
    
    brew install \
        git \
        curl \
        ripgrep \
        fd \
        fzf \
        lazygit \
        neovim \
        node \
        python
    echo "✓ Dependencies installed!"
fi

echo ""
echo "Verifying installations..."
nvim --version | head -n 1
nvim --version | grep -i luajit && echo "✓ LuaJIT support detected" || echo "⚠ Warning: LuaJIT not detected"
node --version 2>/dev/null && echo "✓ Node.js installed" || echo "⚠ Node.js not found"
python3 --version && echo "✓ Python installed" || echo "⚠ Python not found"
echo ""
echo "Run ./install.sh to set up your config!"
