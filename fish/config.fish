# No "Welcome to fish" banner on startup
set -g fish_greeting

if status is-interactive
    # Tab accepts the grey autosuggestion when one is showing, otherwise normal completion
    bind tab 'if commandline --showing-suggestion; commandline -f accept-autosuggestion; else; commandline -f complete; end'
end

# Prompt: current folder name only (+ exit code on failure). The shortened full
# path and git branch are in the tmux status bar (tmux/scripts/location.sh).
function fish_prompt
    set -l last_pipestatus $pipestatus
    set -lx __fish_last_status $status # read by __fish_print_pipestatus
    set -l normal (set_color --reset)
    set -l prompt_status (__fish_print_pipestatus "[" "] " "|" (set_color $fish_color_status) (set_color --bold $fish_color_status) $last_pipestatus)

    set -l dir (path basename $PWD)
    test "$PWD" = "$HOME"; and set dir '~'

    echo -n -s (set_color $fish_color_cwd) $dir $normal ' ' $prompt_status '> '
end
