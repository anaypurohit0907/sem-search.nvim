local M = {}
local treesitter = require('sem-search.treesitter')
local faiss = require('sem-search.faiss')
local config = require('sem-search.config')

local initialized = false
M.is_indexing = false

local function get_index_path()
  local cwd = vim.fn.getcwd()
  local hash = vim.fn.sha256(cwd):sub(1, 10)
  local datapath = vim.fn.stdpath("data") .. "/sem-search"
  vim.fn.mkdir(datapath, "p")
  return datapath .. "/" .. hash
end

local function get_all_files()
  local files = {}
  if vim.fn.isdirectory(".git") == 1 and vim.fn.executable("git") == 1 then
    files = vim.fn.systemlist("git ls-files")
  elseif vim.fn.executable("rg") == 1 then
    files = vim.fn.systemlist("rg --files")
  end
  
  local cwd = vim.fn.getcwd()
  for i, f in ipairs(files) do
    if not f:match("^/") then
      files[i] = cwd .. "/" .. f
    end
  end
  return files
end

function M.init(callback)
  if initialized then 
    if callback then callback() end
    return 
  end
  
  -- Prevent multiple rapid initializations
  if M.is_indexing then return end
  
  faiss.request("init", { index_path = get_index_path() }, function(res, err)
    if not err and res then
      initialized = true
      -- If total chunks == 0, it means it's the first time running in this workspace
      if res.total == 0 and config.options.auto_index then
        vim.schedule(function() 
          M.reindex(callback)
        end)
      else
        if callback then vim.schedule(callback) end
      end
    else
      vim.notify("Failed to init semantic search: " .. (err or "unknown input"), vim.log.levels.ERROR)
    end
  end)
end

function M.reindex(callback)
  if M.is_indexing then
    vim.notify("Index build already in progress...", vim.log.levels.INFO)
    return
  end
  
  local files = get_all_files()
  if #files == 0 then
    vim.notify("SemSearch: No files discovered.", vim.log.levels.WARN)
    return
  end
  
  M.is_indexing = true
  
  -- Extract efficiently 
  local all_chunks = {}
  for _, f in ipairs(files) do
    local chunks = treesitter.get_chunks_from_file(f)
    for _, c in ipairs(chunks) do
      table.insert(all_chunks, c)
    end
  end
  
  vim.notify("🚀 SemSearch: First time in this workspace! Building semantics index with Ollama (" .. #all_chunks .. " chunks). Please wait...", vim.log.levels.INFO)
  
  faiss.request("add_chunks", { chunks = all_chunks }, function(res, err)
    if err then 
      M.is_indexing = false
      vim.notify("Error indexing chunks: " .. err, vim.log.levels.ERROR)
      return
    end
    faiss.request("save", {}, function()
      M.is_indexing = false
      vim.notify("✅ SemSearch: Index properly built and saved! Search is fully ready.", vim.log.levels.INFO)
      if callback then vim.schedule(callback) end
    end)
  end)
end

function M.search(query, callback)
  if not initialized then
    M.init(function()
      M.search(query, callback)
    end)
    return
  end
  
  if M.is_indexing then
    if callback then callback(nil, "Index currently building. Please wait a moment...") end
    return
  end
  
  faiss.request("search", { query = query, k = config.options.max_results }, callback)
end

return M
