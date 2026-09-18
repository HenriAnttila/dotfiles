# Sourced from ~/.zshrc. Keep this file to shortcuts only — machine-generated
# bootstrap (nvm, conda, bun, PATH) stays in ~/.zshrc, which is not tracked.

alias cls='clear'
alias lg='lazygit'
alias ai='claude'

# Open yazi and cd to wherever it was left when it exits.
function y() {
	local tmp="$(mktemp -t "yazi-cwd.XXXXXX")" cwd
	yazi "$@" --cwd-file="$tmp"
	if cwd="$(command cat -- "$tmp")" && [ -n "$cwd" ] && [ "$cwd" != "$PWD" ]; then
		builtin cd -- "$cwd"
	fi
	rm -f -- "$tmp"
}
