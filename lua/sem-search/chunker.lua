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

  local cwd = vim.fn.getcwd()
  local rel_file = filepath
  if string.sub(filepath, 1, #cwd) == cwd then
    rel_file = string.sub(filepath, #cwd + 2)
  end

  local chunk_size = 50
  local overlap = 15

  local i = 1
  while i <= #lines do
    local end_idx = math.min(i + chunk_size - 1, #lines)
    local snippet_lines = {}
    for j = i, end_idx do
      table.insert(snippet_lines, lines[j])
    end
    
    local text = table.concat(snippet_lines, "\n")
    if text:gsub("%s+", "") ~= "" then
      local enhanced_text = "File: " .. rel_file .. "\n" .. text
      
      -- Attempt to find a meaningful semantic name (function, class, struct, etc.) for UI
      local node_name = ""
      local found_fn = text:match("function%s+([%w_%.%:]+)%s*%(") 
                    or text:match("func%s+([%w_]+)%s*%(")
                    or text:match("class%s+([%w_]+)")
                    or text:match("fn%s+([%w_]+)")
                    or text:match("fn%s+[%w_]+%([%w_%*%,%s]-%)%s+([%w_]+)")
                    or text:match("(%w+)%s*=%s*%(.*%)%s*=>")
                    or text:match("(%w+)%s*=%s*function%s*%(")
      
      if found_fn then
        node_name = found_fn
      end
      
      table.insert(chunks, {
        name = node_name,
        line = i,
        text = enhanced_text,
        file = rel_file
      })
    end
    
    if end_idx == #lines then break end
    i = i + chunk_size - overlap
  end
  
  return chunks
end

return M
