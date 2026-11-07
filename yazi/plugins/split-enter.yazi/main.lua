--- @sync entry
-- Enter on a folder: open a tmux split beside yazi, cd'd into that folder.
-- Enter on a file (or outside tmux): the usual `open`.
return {
	entry = function()
		local h = cx.active.current.hovered
		if h and h.cha.is_dir and os.getenv("TMUX") then
			ya.emit("shell", { "tmux split-window -h -c " .. ya.quote(tostring(h.url)), confirm = true })
		else
			ya.emit("open", { hovered = true })
		end
	end,
}
