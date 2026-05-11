local M = {}

M.defaults = {
  keymap = { search = '<leader>ss', workspace_search = '<leader>sw', setup = '<leader>uS', reindex = '<leader>si' },
  ollama_host = 'localhost:11434',
  embed_model = 'nomic-embed-text',
  max_results = 10,
  chunk_size_lines = 50,
  chunk_overlap_lines = 15,
  auto_index = true,
  batch_size = 100,
  max_workers = 8,
  ignore_patterns = { "\\.git/", "node_modules/", "vendor/", "\\.venv/", "dist/", "build/", "docs/" },
  ignore_enabled = true,
  include_global_in_search = false,
  global_kb_auto_save = true,
  colors = { score = 'DiagnosticHint', path = 'String', func = 'Function' },
}

M.options = {}

function M.setup(opts)
  M.options = vim.tbl_deep_extend('force', M.defaults, opts or {})
end

return M
