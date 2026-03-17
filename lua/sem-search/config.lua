local M = {}

M.defaults = {
  keymap = { search = '<leader>ss', workspace_search = '<leader>sw', setup = '<leader>uS', reindex = '<leader>si' },
  ollama_host = 'localhost:11434',
  embed_model = 'nomic-embed-text',
  max_results = 10,
  chunk_size = 10000,
  auto_index = true,
  ignore_patterns = { "\\.git/", "node_modules/", "vendor/", "\\.venv/", "dist/", "build/", "docs/" },
  ignore_enabled = true,
  colors = { score = 'DiagnosticHint', path = 'String', func = 'Function' },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M
