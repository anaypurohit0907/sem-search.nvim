local M = {}

function M.get_chunks_from_file(filepath)
  local file = io.open(filepath, "r")
  if not file then return {} end
  local content = file:read("*a")
  file:close()
  
  if content == "" then return {} end

  local chunks = {}
  -- Split lines efficiently
  local lines = vim.split(content, "\n", {plain=true})

  local symbol_lines = {}
  local current_symbol = ""
  for idx, line in ipairs(lines) do
    local found = line:match("^%s*function%s+([%w_%.%:]+)%s*%(") 
               or line:match("^%s*local%s+function%s+([%w_%.%:]+)%s*%(")
               or line:match("^%s*func%s+([%w_%.%:]+)%s*%(")
               or line:match("^%s*class%s+([%w_]+)")
               or line:match("^%s*fn%s+([%w_]+)")
               or line:match("^%s*pub%s+fn%s+([%w_]+)")
               or line:match("^%s*def%s+([%w_]+)")
               
    if found then
      current_symbol = found
    end
    -- Very naive reset on top-level block endings
    if line:match("^}$") or line:match("^end$") then
      current_symbol = "" 
    end
    symbol_lines[idx] = current_symbol
  end

  local cwd = vim.fn.getcwd()
  local rel_file = filepath
  if string.sub(filepath, 1, #cwd) == cwd then
    rel_file = string.sub(filepath, #cwd + 2)
  end

  local chunk_size = 50
  local overlap = 15

  local i = 1
  local mtime = vim.fn.getftime(filepath)
  while i <= #lines do
    local end_idx = math.min(i + chunk_size - 1, #lines)
    local snippet_lines = {}
    for j = i, end_idx do
      table.insert(snippet_lines, lines[j])
    end
    
    local text = table.concat(snippet_lines, "\n")
    if text:gsub("%s+", "") ~= "" then
      -- Find the first valid symbol that appears in this chunk
      local node_name = ""
      for j = i, end_idx do
        if symbol_lines[j] and symbol_lines[j] ~= "" then
          node_name = symbol_lines[j]
          break
        end
      end
      
      local context_str = ""
      if node_name ~= "" then
         context_str = "Context: " .. node_name .. "\n"
      end
      
      local enhanced_text = "File: " .. rel_file .. "\n" .. context_str .. text
      
      table.insert(chunks, {
        name = node_name,
        line = i,
        text = enhanced_text,
        code_text = text,
        file = rel_file,
        mtime = mtime
      })
    end
    
    if end_idx == #lines then break end
    i = i + chunk_size - overlap
  end
  
  return chunks
end

return M
