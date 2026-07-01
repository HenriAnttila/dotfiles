return {
  "folke/snacks.nvim",
  priority = 1000,
  lazy = false,
  ---@type snacks.Config
  opts = {
    picker = {
      sources = {
        explorer = {
          layout = {
            auto_hide = { "input" },
          },
          actions = {
            -- create a barrel-export component inside the hovered folder
            barrel = function(picker)
              local dir = picker:dir()
              Snacks.input({ prompt = "Component name: " }, function(name)
                local comp = require("util.barrel").create(dir, name)
                if comp then
                  -- refresh the tree and reveal the new component file
                  require("snacks.explorer.actions").update(picker, { target = comp, refresh = true })
                end
              end)
            end,
          },
          win = {
            list = {
              keys = {
                ["B"] = "barrel",
              },
            },
          },
        },
      },
    },
  },
}
