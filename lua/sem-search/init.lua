local config = require('sem-search.config')
local ui = require('sem-search.ui')
local index = require('sem-search.index')

local M = {}

function M.setup(opts)
  config.setup(opts)

  -- Setup Commands
  vim.api.nvim_create_user_command('Semetup', function()
    index.reindex()
  end, {})

  -- Keybindings
  local k = config.options.keymap
  vim.keymap.set('n', k.search, function() ui.search() end, { desc = "Semantic Search" })
  vim.keymap.set('n', k.setup, function() print("Toggle config not fully implemented") end, { desc = "SemSearch Config" })
  vim.keymap.set('n', k.reindex, function() index.reindex() end, { desc = "SemSearch Reindex" })
end

return M
