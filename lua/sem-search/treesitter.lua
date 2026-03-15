local M = {}

M.queries = {
  lua = '(function_declaration name: (identifier) @symbol)',
  typescript = '(method_definition name: (property_identifier) @symbol)',
  python = '(function_definition name: (identifier) @symbol)',
  go = '(method_declaration name: (field_identifier) @symbol)',
  rust = '(function_item name: (identifier) @symbol)',
}

-- Extract chunks for embedding
function M.get_chunks(bufnr, lang)
  local query_string = M.queries[lang]
  if not query_string then return {} end
  
  local ok, query = pcall(vim.treesitter.query.parse, lang, query_string)
  if not ok then return {} end

  local parser = vim.treesitter.get_parser(bufnr, lang)
  if not parser then return {} end
  
  local tree = parser:parse()[1]
  local root = tree:root()
  
  local chunks = {}
  for id, node, m in query:iter_captures(root, bufnr, 0, -1) do
    local name = vim.treesitter.get_node_text(node, bufnr)
    local start_row, _, end_row, _ = node:range()
    
    local lines = vim.api.nvim_buf_get_lines(bufnr, start_row, end_row + 1, false)
    local text = table.concat(lines, "\n")
    
    table.insert(chunks, {
        name = name,
        line = start_row + 1,
        text = text
    })
  end
  return chunks
end

return M
