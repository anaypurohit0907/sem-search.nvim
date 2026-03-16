local config = require('sem-search.config')
local ui = require('sem-search.ui')
local index = require('sem-search.index')

local M = {}

function M.setup(opts)
  config.setup(opts)

  -- Setup Commands
  vim.api.nvim_create_user_command('SemStatus', function()
    index.status()
  end, {})
  
  vim.api.nvim_create_user_command('Semsetup', function()
    index.reindex()
  end, {})

  -- Keybindings
  local k = config.options.keymap
  vim.keymap.set('n', k.search, function() ui.search({ workspace = false }) end, { desc = "Semantic Search (Current File)" })
  vim.keymap.set('n', k.workspace_search, function() ui.search({ workspace = true }) end, { desc = "Semantic Search (Workspace)" })
  vim.keymap.set('n', k.setup, function() print("Toggle config not fully implemented") end, { desc = "SemSearch Config" })
  vim.keymap.set('n', k.reindex, function() index.reindex() end, { desc = "SemSearch Reindex" })

  -- Auto-index on save
  if config.options.auto_index then
    vim.api.nvim_create_autocmd("BufWritePost", {
      group = vim.api.nvim_create_augroup("SemSearchAutoIndex", { clear = true }),
      pattern = "*",
      callback = function()
        -- Silent incremental update in the background
        index.reindex(nil, { 
          on_index_progress = function() end, -- No noisy UI for auto-save
          on_error = function(err) 
            -- Only notify on significant errors, not background noise
            if not err:match("not initialized") then
              vim.notify("SemSearch Auto-index error: " .. err, vim.log.levels.DEBUG)
            end
          end 
        })
      end
    })
  end
end

return M
