local M = {}
local config = require('sem-search.config')

local job_id = nil
local callbacks = {}
local req_id = 0
local deps_checked = false

function M.check_and_install_deps(callback, ctx)
  if deps_checked then 
    if callback then callback(true) end
    return 
  end
  
  if vim.fn.executable("python3") == 0 then
    if ctx and ctx.on_error then ctx.on_error("python3 executable not found in PATH!") end
    if callback then callback(false) end
    return
  end

  local function check_model()
    local model_name = config.options.embed_model
    vim.fn.jobstart({"python3", "-c", "import ollama; ollama.show('" .. model_name .. "')"}, {
      on_exit = function(_, model_code)
        if model_code == 0 then
          deps_checked = true
          if callback then callback(true) end
        else
          if ctx and ctx.on_install_prompt then
            ctx.on_install_prompt(function(choice)
              if choice then
                if ctx.on_install_progress then ctx.on_install_progress("Pulling model " .. model_name .. "...") end
                vim.fn.jobstart({"ollama", "pull", model_name}, {
                  on_exit = function(_, pull_code)
                    vim.schedule(function()
                      if pull_code == 0 then
                        deps_checked = true
                        if callback then callback(true) end
                      else
                        if ctx.on_error then ctx.on_error("Failed to pull model: " .. model_name) end
                        if callback then callback(false) end
                      end
                    end)
                  end
                })
              else
                if callback then callback(false) end
              end
            end, "  📦 Ollama model missing!", "  (" .. model_name .. " requires pull)")
          else
             vim.notify("sem-search: Missing Ollama model: " .. model_name, vim.log.levels.ERROR)
             if callback then callback(false) end
          end
        end
      end
    })
  end

  vim.fn.jobstart({"python3", "-c", "import faiss, numpy, ollama"}, {
    on_exit = function(_, code)
      if code == 0 then
        check_model()
      else
        if ctx and ctx.on_install_prompt then
          ctx.on_install_prompt(function(choice)
            if choice then
              if ctx.on_install_progress then ctx.on_install_progress("Installing faiss-cpu, numpy, ollama...") end
              vim.fn.jobstart({"python3", "-m", "pip", "install", "faiss-cpu", "numpy", "ollama"}, {
                on_exit = function(_, install_code)
                  vim.schedule(function()
                    if install_code == 0 then
                      check_model()
                    else
                      if ctx.on_error then ctx.on_error("Failed to install dependencies.") end
                      if callback then callback(false) end
                    end
                  end)
                end
              })
            else
              if callback then callback(false) end
            end
          end)
        else
           vim.notify("sem-search: Missing Python dependencies.", vim.log.levels.ERROR)
           if callback then callback(false) end
        end
      end
    end
  })
end

function M.start_server(cb, ctx)
  if job_id then 
    if cb then cb(true) end
    return 
  end
  
  M.check_and_install_deps(function(ok)
    if not ok then
      if cb then cb(false) end
      return
    end

    local script_path = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/python/faiss_server.py"
    
    local stdout_buf = ""
    job_id = vim.fn.jobstart({"python3", "-u", script_path}, {
      on_stdout = function(_, data)
        if not data then return end
        
        for i, chunk in ipairs(data) do
          stdout_buf = stdout_buf .. chunk
          if i < #data then
            -- When we are not at the final fragment of the `data` array,
            -- Neovim implies there was a newline after this chunk.
            local line = stdout_buf
            stdout_buf = "" -- Reset buffer for the next line
            
            if line ~= "" then
              local ok_json, decoded = pcall(vim.fn.json_decode, line)
              if ok_json and decoded and decoded.id and callbacks[decoded.id] then
                -- Convert vim.NIL to standard lua `nil` so 'if err' logic flows perfectly inside callbacks.
                local res = decoded.result
                if res == vim.NIL or type(res) == "userdata" then res = nil end
                local err = decoded.error
                if err == vim.NIL or type(err) == "userdata" then err = nil end
                
                local cb_func = callbacks[decoded.id]
                callbacks[decoded.id] = nil
                if cb_func then cb_func(res, err) end
              end
            end
          end
        end
      end,
      on_stderr = function(_, data) end,
      on_exit = function()
        job_id = nil
      end
    })
    
    if cb then cb(job_id ~= nil) end
  end, ctx)
end

function M.request(cmd, args, callback, ctx)
  M.start_server(function(ok)
    if not ok then 
      if callback then callback(nil, "Failed to start server or missing dependencies") end
      return 
    end
    
    req_id = req_id + 1
    callbacks[req_id] = callback
    
    local payload = vim.fn.json_encode({
      id = req_id,
      cmd = cmd,
      args = args or {}
    })
    
    vim.fn.chansend(job_id, payload .. "\n")
  end, ctx)
end

return M
