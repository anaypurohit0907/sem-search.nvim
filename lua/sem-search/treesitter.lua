local M = {}

M.ext_to_lang = {
  lua = "lua",
  ts = "typescript",
  py = "python",
  go = "go",
  rs = "rust",
  js = "javascript"
}

M.queries = {
  lua = '(function_declaration name: [(identifier) (dot_index_expression)] @symbol)',
  typescript = '(function_declaration name: (identifier) @symbol) (method_definition name: (property_identifier) @symbol) (variable_declarator name: (identifier) @symbol value: (arrow_function))',
  javascript = '(function_declaration name: (identifier) @symbol) (method_definition name: (property_identifier) @symbol) (variable_declarator name: (identifier) @symbol value: (arrow_function))',
  python = '(function_definition name: (identifier) @symbol) (class_definition name: (identifier) @symbol)',
  go = '(function_declaration name: (identifier) @symbol) (method_declaration name: (field_identifier) @symbol)',
  rust = '(function_item name: (identifier) @symbol)',
}

function M.get_chunks_from_file(filepath)
  local ext = vim.fn.fnamemodify(filepath, ":e")
  local lang = M.ext_to_lang[ext]
  if not lang then return {} end
  
  local query_string = M.queries[lang]
  if not query_string then return {} end

  local file = io.open(filepath, "r")
  if not file then return {} end
  local content = file:read("*a")
  file:close()
  
  if content == "" then return {} end

  local ok, parser = pcall(vim.treesitter.get_string_parser, content, lang)
  if not ok or not parser then return {} end
  
  local tree = parser:parse()[1]
  if not tree then return {} end
  local root = tree:root()
  
  local ok_query, query = pcall(vim.treesitter.query.parse, lang, query_string)
  if not ok_query then return {} end

  local chunks = {}
  -- Split lines efficiently
  local lines = vim.split(content, "\n", {plain=true})

  for id, node, m in query:iter_captures(root, content, 0, -1) do
    local name = vim.treesitter.get_node_text(node, content)
    local parent = node:parent()
    if parent then
      local start_row, start_col, end_row, end_col = parent:range()
      
      local snippet_lines = {}
      for i = start_row + 1, end_row + 1 do
        if lines[i] then
          table.insert(snippet_lines, lines[i])
        end
      end
      local text = table.concat(snippet_lines, "\n")
      
      local cwd = vim.fn.getcwd()
      local rel_file = filepath
      if string.sub(filepath, 1, #cwd) == cwd then
        rel_file = string.sub(filepath, #cwd + 2)
      end

      table.insert(chunks, {
        name = name,
        line = start_row + 1,
        text = text,
        file = rel_file
      })
    end
  end
  
  return chunks
end

return M
