local M = {}

local function is_lang_aware_chunk_end(line, lang)
  if line:match("^%s*end%s*$") then return true end
  if line:match("^%s*}%s*$") then return true end
  if lang == "python" and line:match("^%s*(@[a-zA-Z_][a-zA-Z0-9_]*)$") then return true end
  return false
end

local function detect_language(filepath)
  local ext = filepath:match("%.(%w+)$") or ""
  local langs = {
    lua = true, py = true, js = true, ts = true, jsx = true, tsx = true,
    rs = true, go = true, java = true, cpp = true, cc = true, cxx = true,
    c = true, h = true, hpp = true, cs = true, rb = true, swift = true,
    kt = true, scala = true, php = true, vue = true, svelte = true,
  }
  return langs[ext] and ext or "generic"
end

function M.get_chunks_from_file(filepath)
  local file = io.open(filepath, "r")
  if not file then return {} end
  local content = file:read("*a")
  file:close()

  if content == "" then return {} end

  local lines = vim.split(content, "\n", {plain=true})
  local lang = detect_language(filepath)

  local symbol_lines = {}
  local current_symbol = ""
  local in_block = false

  for idx, line in ipairs(lines) do
    local found = line:match("^%s*function%s+([%w_%.%:]+)%s*%(")
               or line:match("^%s*local%s+function%s+([%w_%.%:]+)%s*%(")
               or line:match("^%s*func%s+([%w_%.%:]+)%s*%(")
               or line:match("^%s*class%s+([%w_]+)")
               or line:match("^%s*fn%s+([%w_]+)")
               or line:match("^%s*pub%s+fn%s+([%w_]+)")
               or line:match("^%s*def%s+([%w_]+)")
               or line:match("^%s*async%s+fn%s+([%w_]+)")

    if found then
      current_symbol = found
      in_block = true
    elseif in_block and is_lang_aware_chunk_end(line, lang) then
      current_symbol = ""
      in_block = false
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

  local seen_hashes = {}
  local chunks = {}
  local i = 1
  local mtime = vim.fn.getftime(filepath)

  while i <= #lines do
    local end_idx = math.min(i + chunk_size - 1, #lines)
    local snippet_lines = {}
    for j = i, end_idx do
      table.insert(snippet_lines, lines[j])
    end

    local code_text = table.concat(snippet_lines, "\n")
    local stripped = code_text:gsub("%s+", "")
    if stripped ~= "" then
      local hash = vim.fn.sha256(code_text):sub(1, 16)
      if not seen_hashes[hash] then
        seen_hashes[hash] = true

        local node_name = ""
        for j = i, end_idx do
          if symbol_lines[j] and symbol_lines[j] ~= "" then
            node_name = symbol_lines[j]
            break
          end
        end

        table.insert(chunks, {
          name = node_name,
          line = i,
          code_text = code_text,
          file = rel_file,
          mtime = mtime,
        })
      end
    end

    if end_idx == #lines then break end
    i = i + chunk_size - overlap
  end

  return chunks
end

function M.get_text(chunk)
  local ctx_str = chunk.name and chunk.name ~= "" and ("Context: " .. chunk.name .. "\n") or ""
  return "File: " .. chunk.file .. "\n" .. ctx_str .. (chunk.code_text or "")
end

return M