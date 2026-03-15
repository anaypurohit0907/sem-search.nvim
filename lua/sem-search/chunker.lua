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

  local chunk_size = 20
  local overlap = 5

  local i = 1
  while i <= #lines do
    local end_idx = math.min(i + chunk_size - 1, #lines)
    local snippet_lines = {}
    for j = i, end_idx do
      table.insert(snippet_lines, lines[j])
    end
    
    local text = table.concat(snippet_lines, "\n")
    if text:gsub("%s+", "") ~= "" then
      table.insert(chunks, {
        name = "Lines " .. i .. "-" .. end_idx,
        line = i,
        text = text,
        file = rel_file
      })
    end
    
    if end_idx == #lines then break end
    i = i + chunk_size - overlap
  end
  
  return chunks
end

return M
