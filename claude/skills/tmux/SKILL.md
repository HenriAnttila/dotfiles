---
name: tmux
description: Open things in the user's tmux from this session, as a popup over the conversation or beside it (a split, or a new window when this row already has three panes side by side). Use when the user asks to see, show, open or pull up something in tmux, a popup, a split or a window, such as their website, a page, an html file, logs, a dev server or a TUI. "Show me my website" opens it in a popup. For web pages this decides where terminal-browser opens; the terminal-browser skill covers driving the page.
---

This session runs inside the user's tmux. `$TMUX_PANE` is the pane Claude Code
is in: target it, so things open over or next to this conversation.

tmux runs a pane's command through fish, the user's default-shell. Pass the
command as separate arguments after `--`, which runs it without a shell, never
as one quoted string.

You cannot see the screen. `capture-pane` gives a pane's text, not images, and
a popup cannot be captured at all.

## Popup or split

- **Popup**: something the user looks at and closes. "Show me my website" is a
  popup.
- **Split**: something kept open while you keep working together: logs, a dev
  server, a page you are changing.
- When the user names one, use that.

A popup takes every key until it closes, so the user cannot type to you while
it is open. Tell them how to close it: ctrl+q for terminal-browser, otherwise
whatever ends the command.

## Popup

```sh
~/.claude/skills/tmux/scripts/popup.py [-w 85%] [-h 85%] [-T title] [-d dir] -- <command> [args...]
```

It returns at once and the popup closes when the command exits. Always open
terminal-browser in a popup through this script, never with
`tmux display-popup` directly: a popup reports no pixel size, and without the
script's fix terminal-browser renders the page at the wrong scale.

There is one popup at a time. `tmux display-popup -C` closes it from here.

## Split

Never call `tmux split-window` yourself, and never let terminal-browser split
(`--split`, or `open` with no TTY, which splits on its own). Open everything
that goes beside the conversation through:

```sh
~/.tmux/scripts/open-beside.sh -d -n <name> -c "$PWD" "$TMUX_PANE" -- <command> [args...]
```

While this pane's row has one or two panes side by side it opens a 50% split
to the right; once the row already has three (panes stacked above or below
don't count) it opens a new window (tab) named `<name>` instead, so nothing gets
squeezed into a narrow fourth column. When it
opened a window, tell the user it's in the next tab. `-d` leaves the user's
keyboard on this conversation. It prints the new pane's id; keep it for:

- reading it: `tmux capture-pane -p -t <id> -S -200`
- typing into it: `tmux send-keys -t <id> C-c`, `tmux send-keys -t <id> 'npm run dev' Enter`
- closing it: `tmux kill-pane -t <id>`

Open a page beside the conversation with
`open-beside.sh -d -n browser "$TMUX_PANE" -- terminal-browser open <url>`:
inside the new pane it has a TTY, so it takes that pane instead of splitting
again, and you get the pane id back.

Something that runs in the background and that nobody needs to watch, like a
dev server, goes in its own window instead:
`tmux new-window -d -n <name> -c "$PWD" -- <command>`.

## "Show me my website"

1. Find the port the project's dev server is on. `lsof -nP -iTCP -sTCP:LISTEN`
   lists what is listening; the dev script and config in the project say which
   port it uses. Without either, it is `localhost:3000`.
2. Check it answers: `curl -s -o /dev/null -w '%{http_code}' <url>`.
3. If nothing answers, say so and ask before starting the dev server.
4. `~/.claude/skills/tmux/scripts/popup.py -T <site> -- terminal-browser open <url>`

A page on the site, like "show me the contract page", is that path on the same
url. A local html file opens by its absolute path.

## Driving a browser in a popup

terminal-browser lists a browser in a popup as "no pane", so
`terminal-browser action` does not find it by default. Get its key from
`terminal-browser ls --all` and pass `--browser <key>`:

```sh
terminal-browser action --browser 32109-1 -- snapshot
```

The rest is in the terminal-browser skill.
