return {
  "folke/flash.nvim",
  keys = {
    {
      "<leader>S",
      mode = { "n", "x", "o" },
      function()
        require("flash").jump({
          pattern = ".", -- seed so all tags are matched before you type
          search = {
            mode = function(pattern)
              -- strip the seed dot, then match < or </ + what you've typed + rest of tag name
              if pattern:sub(1, 1) == "." then
                pattern = pattern:sub(2)
              end
              return ([[<\/\?\zs%s\w*]]):format(pattern)
            end,
          },
          jump = { pos = "start" },
        })
      end,
      desc = "Flash to tags (type to filter)",
    },
  },
}
