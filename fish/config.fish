# No "Welcome to fish" banner on startup
set -g fish_greeting

if status is-interactive
    # Tab accepts the grey autosuggestion when one is showing, otherwise normal completion
    bind tab 'if commandline --showing-suggestion; commandline -f accept-autosuggestion; else; commandline -f complete; end'
end
