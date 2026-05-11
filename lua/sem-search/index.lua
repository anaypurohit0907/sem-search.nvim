local M = {}
local chunker = require('sem-search.chunker')
local faiss = require('sem-search.faiss')
local config = require('sem-search.config')

local initialized = false
local initialized_cwd = nil
M.is_indexing = false
M.auto_indexing = false

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
    files = vim.fn.systemlist("rg --files --hidden -g '!.git/'")
  else
    files = vim.fn.systemlist("find . -type f -not -path '*/\\.git/*'")
  end

  if #files == 0 then
    files = vim.fn.systemlist("find . -type f -not -path '*/\\.git/*'")
  end

  local clean_files = {}
  local cwd = vim.fn.getcwd()
  for _, f in ipairs(files) do
    if f and f ~= "" and not f:match("%.git/") and not f:match("%.png$") and not f:match("%.jpg$") then
      if not f:match("^/") then
        table.insert(clean_files, cwd .. "/" .. f)
      else
        table.insert(clean_files, f)
      end
    end
  end
  return clean_files
end

function M.init(callback, ctx)
  local current_cwd = vim.fn.getcwd()
  if initialized and current_cwd == initialized_cwd then
    if callback then callback() end
    return
  end

  if M.is_indexing and not M.auto_indexing then
    if callback then callback(nil, "Index currently building. Please wait a moment...") end
    return
  end

  faiss.request("init", {
      index_path = get_index_path(),
      batch_size = config.options.batch_size,
      max_workers = config.options.max_workers
    }, function(res, err)
    if not err and res then
      initialized = true
      initialized_cwd = current_cwd
      if res.total == 0 and config.options.auto_index then
        vim.schedule(function()
          M.reindex(callback, ctx)
        end)
      else
        if callback then vim.schedule(callback) end
      end
    else
      if ctx and ctx.on_error then
          local e_str = tostring(err or "unknown input")
          if err == vim.NIL or type(err) == "userdata" then
            e_str = "unknown userdata error"
          end
          ctx.on_error("Failed to init semantic search: " .. e_str)
      else
          vim.notify("Failed to init semantic search", vim.log.levels.ERROR)
      end
    end
  end, ctx)
end

function M.reindex(callback, ctx)
  if M.is_indexing and not M.auto_indexing then return end

  M.is_indexing = true
  M.auto_indexing = ctx and ctx.auto_index or false
  M.indexing_start_time = nil

  local files = get_all_files()
  if #files == 0 then
    if ctx and ctx.on_error then ctx.on_error("SemSearch: No files discovered.") end
    M.is_indexing = false
    M.auto_indexing = false
    if ctx and ctx.on_done then ctx.on_done() end
    return
  end

  faiss.request("get_file_stats", {}, function(server_stats, err)
    if err then
      M.is_indexing = false
      M.auto_indexing = false
      if ctx and ctx.on_done then ctx.on_done() end
      if ctx and ctx.on_error then ctx.on_error("Error getting file stats: " .. err) end
      return
    end

    local stats = server_stats or {}
    local files_to_index = {}
    local files_to_drop = {}
    local files_seen_local = {}

    for _, f in ipairs(files) do
      local mtime = vim.fn.getftime(f)
      files_seen_local[f] = true
      if not stats[f] or mtime > (stats[f] or 0) then
        table.insert(files_to_index, f)
        if stats[f] then
          table.insert(files_to_drop, f)
        end
      end
    end

    for f, _ in pairs(stats) do
      if not files_seen_local[f] then
        table.insert(files_to_drop, f)
      end
    end

    if ctx and ctx.on_index_progress then
      ctx.on_index_progress("Indexing " .. #files_to_index .. " files...", 5, nil, nil)
    end

    local new_chunks = {}
    for _, f in ipairs(files_to_index) do
      local raw_chunks = chunker.get_chunks_from_file(f)
      for _, c in ipairs(raw_chunks) do
        c.text = chunker.get_text(c)
        table.insert(new_chunks, c)
      end
    end

    if #new_chunks == 0 and #files_to_drop == 0 then
      M.is_indexing = false
      M.auto_indexing = false
      if ctx and ctx.on_done then ctx.on_done() end
      if ctx and ctx.on_index_progress then ctx.on_index_progress("Index is up to date!", 100, nil, nil) end
      if callback then vim.schedule(callback) end
      return
    end

    if ctx and ctx.on_index_progress then
      ctx.on_index_progress("Embedding " .. #new_chunks .. " chunks...", 15, #new_chunks, 0)
    end

    faiss.request("update_delta", {
      chunks = new_chunks,
      drop = files_to_drop,
      model = config.options.embed_model,
      batch_size = config.options.batch_size,
      max_workers = config.options.max_workers
    }, function(res, delta_err)
      if delta_err then
        M.is_indexing = false
        M.auto_indexing = false
        if ctx and ctx.on_done then ctx.on_done() end
        if ctx and ctx.on_error then ctx.on_error("Error updating index: " .. delta_err) end
        return
      end

      M.is_indexing = false
      M.auto_indexing = false
      if ctx and ctx.on_done then ctx.on_done() end
      if ctx and ctx.on_index_progress then ctx.on_index_progress("Done!", 100, nil, nil) end
      if callback then vim.schedule(callback) end
    end, ctx)
  end, ctx)
end

function M.status(callback)
  faiss.request("status", {}, function(res, err)
    if err then
      vim.notify("SemSearch Status Error: " .. tostring(err), vim.log.levels.ERROR)
      if callback then callback(nil) end
      return
    end
    if res then
      local status_msg = string.format("SemSearch: %d chunks indexed. Status: %s", res.total_chunks, res.healthy and "Healthy" or "Issues detected")
      vim.notify(status_msg, res.healthy and vim.log.levels.INFO or vim.log.levels.WARN)
    end
    if callback then callback(res) end
  end)
end

function M.search(query, in_opts, callback, ctx)
  if type(in_opts) == "function" then
    ctx = callback
    callback = in_opts
    in_opts = {}
  end
  in_opts = in_opts or {}

  if not initialized then
    M.init(function()
      M.search(query, in_opts, callback, ctx)
    end, ctx)
    return
  end

  if M.is_indexing and not M.auto_indexing then
    if callback then callback(nil, "Index currently building. Please wait a moment...") end
    return
  end

  local req_args = {
    query = query,
    k = config.options.max_results,
    model = config.options.embed_model,
    file_filter = in_opts.file_filter,
    ignore_patterns = in_opts.ignore_patterns
  }
  faiss.request("search", req_args, callback, ctx)
end

return M