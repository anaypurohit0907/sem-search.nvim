local old_content = io.open("lua/sem-search/faiss.lua", "r"):read("*a")
local new_content = old_content:gsub("local M = {}", "local M = {}\nlocal config = require('sem-search.config')")

local search_block = [[
function M.check_and_install_deps%(callback, ctx%)
  if deps_checked then 
    if callback then callback%(true%) end
    return 
  end
  
  if vim.fn.executable%("python3"%) == 0 then
    if ctx and ctx.on_error then ctx.on_error%("python3 executable not found in PATH!"%) end
    if callback then callback%(false%) end
    return
  end

  vim.fn.jobstart%({"python3", "%-c", "import faiss, numpy, ollama"}, {
    on_exit = function%(_, code%)
      if code == 0 then
        deps_checked = true
        if callback then callback%(true%) end
      else
        if ctx and ctx.on_install_prompt then
          ctx.on_install_prompt%(function%(choice%)
            if choice then
              if ctx.on_install_progress then ctx.on_install_progress%("Installing faiss%-cpu, numpy, ollama..."%) end
              vim.fn.jobstart%({"python3", "%-m", "pip", "install", "faiss%-cpu", "numpy", "ollama"}, {
                on_exit = function%(_, install_code%)
                  vim.schedule%(function%(%)
                    if install_code == 0 then
                      deps_checked = true
                      if callback then callback%(true%) end
                    else
                      if ctx.on_error then ctx.on_error%("Failed to install dependencies."%) end
                      if callback then callback%(false%) end
                    end
                  end%)
                end
              })
            else
              if callback then callback%(false%) end
            end
          end%)
        else
           vim.notify%("sem%-search: Missing Python dependencies.", vim.log.levels.ERROR%)
           if callback then callback%(false%) end
        end
      end
    end
  })
end
]]

local replacement = [[
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
          end) -- default args for deps
        else
           vim.notify("sem-search: Missing Python dependencies.", vim.log.levels.ERROR)
           if callback then callback(false) end
        end
      end
    end
  })
end
]]

new_content = new_content:gsub(search_block, replacement)

io.open("lua/sem-search/faiss.lua", "w"):write(new_content)
print("Done patching faiss.lua")
