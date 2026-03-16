if vim.fn.has("nvim-0.9.0") == 0 then
  vim.api.nvim_err_writeln("sem-search.nvim requires Neovim >= 0.9.0")
  return
end

-- We no longer call setup() automatically here.
-- Users should call require('sem-search').setup() in their config
-- to ensure their custom settings are applied correctly.
