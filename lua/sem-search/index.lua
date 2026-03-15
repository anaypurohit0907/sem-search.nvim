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

function M.init(callback, ctx)
  if initialized then 
    if callback then callback() end
    return 
  end
  
  if M.is_indexing then return end
  
  faiss.request("init", { index_path = get_index_path() }, function(res, err)
    if not err and res then
      initialized = true
      if res.total == 0 and config.options.auto_index then
        vim.schedule(function() 
          M.reindex(callback, ctx)
        end)
      else
        if callback then vim.schedule(callback) end
      end
    else
      if ctx and ctx.on_error then 
          local e_str = (type(err) == "userdata") and "unknown userdata error" or tostring(err or "unknown input")
          ctx.on_error("Failed to init semantic search: " .. e_str) 
      else
          vim.notify("Failed to init semantic search", vim.log.levels.ERROR)
      end
    end
  end, ctx)
end

function M.reindex(callback, ctx)
  if M.is_indexing then return end
  
  M.is_indexing = true
  if ctx and ctx.on_index_progress then ctx.on_index_progress("Discovering files...") end
  
  local files = get_all_files()
  if #files == 0 then
    if ctx and ctx.on_error then ctx.on_error("SemSearch: No files discovered.") end
    M.is_indexing = false
    return
  end
  
  if ctx and ctx.on_index_progress then ctx.on_index_progress("Extracting code chunks locally...") end
  
  local all_chunks = {}
  for _, f in ipairs(files) do
    local chunks = treesitter.get_chunks_from_file(f)
    for _, c in ipairs(chunks) do
      table.insert(all_chunks, c)
    end
  end
  
  if ctx and ctx.on_index_progress then ctx.on_index_progress("Generating embeddings (" .. #all_chunks .. " chunks). This may take a minute...") end
  
  faiss.request("add_chunks", { chunks = all_chunks }, function(res, err)
    if err then 
      M.is_indexing = false
      if ctx and ctx.on_error then ctx.on_error("Error indexing chunks: " .. err) end
      return
    end
    
    if ctx and ctx.on_index_progress then ctx.on_index_progress("Saving index to disk...") end
    
    faiss.request("save", {}, function()
      M.is_indexing = false
      if callback then vim.schedule(callback) end
    end, ctx)
  end, ctx)
end

function M.search(query, callback, ctx)
  if not initialized then
    M.init(function()
      M.search(query, callback, ctx)
    end, ctx)
    return
  end
  
  if M.is_indexing then
    if callback then callback(nil, "Index currently building. Please wait a moment...") end
    return
  end
  
  faiss.request("search", { query = query, k = config.options.max_results }, callback, ctx)
end

return M
