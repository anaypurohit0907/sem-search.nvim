local config = require('sem-search.config')
local index = require('sem-search.index')

local M = {}

-- Global UI State allowing users to close the window and re-open smoothly
M.app_state = "pending" -- pending, prompt_install, installing, indexing, ready, searching, results
M.progress_msg = ""
M.pending_resolve = nil
M.current_results = {}
M.search_start_time = nil

local spinner_frames = {'⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'}
local tips = {
  " Use `%` to jump between matching brackets.",
  "help` is your best friend!",
  " Why do programmers prefer dark mode? Because light attracts bugs.",
  " `ciw` changes the inner word under your cursor.",
  " I have a joke about UDP, but you might not get it.",
  " Use `<C-o>` and `<C-i>` to navigate backwards and forwards.",
  " There are 10 types of people: those who understand binary, and those who don't.",
  " How many programmers does it take to change a light bulb? None, that's a hardware problem.",
  " `zz` centers your cursor on the screen immediately.",
}

local active_win = nil
local active_buf = nil

local function jump_to_result(split_cmd)
  if not active_win or not vim.api.nvim_win_is_valid(active_win) then return end
  local cursor_ok, cursor = pcall(vim.api.nvim_win_get_cursor, active_win)
  if not cursor_ok then return end

  local row = cursor[1]
  local res_idx = row
  local res = M.current_results[res_idx]

  if res and res.file then
    vim.cmd('q')
    if split_cmd then vim.cmd(split_cmd) end
    vim.cmd("edit " .. res.file)
    pcall(vim.api.nvim_win_set_cursor, 0, {res.line, 0})
    vim.cmd("normal! zz")
  end
end

local function get_bouncing_bar(idx, width)
  local pos = idx % (width * 2)
  if pos < width then
    return string.rep("=", pos) .. ">" .. string.rep(" ", math.max(0, width - pos - 1))
  else
    local back = width - (pos - width) - 1
    return string.rep(" ", math.max(0, back)) .. "<" .. string.rep("=", math.max(0, width - back - 1))
  end
end

function M.search(opts)
  opts = opts or {}
  local current_file = vim.api.nvim_buf_get_name(0)
  if current_file ~= "" then
    local cwd = vim.fn.getcwd()
    if vim.startswith(current_file, cwd) then
      current_file = current_file:sub(#cwd + 2)
    end
  else
    current_file = nil
  end
  local file_filter = opts.workspace and nil or current_file

  local width = 80
  local height = 15
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local results_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[results_buf].bufhidden = "wipe"
  local results_title = file_filter and ' 🎯 Semantic Search (File) ' or ' 🎯 Semantic Search (Workspace) '
  local results_win = vim.api.nvim_open_win(results_buf, true, {
    relative = 'editor', width = width, height = height, row = row, col = col,
    style = 'minimal', border = 'rounded', title = results_title, title_pos = 'center',
    footer = ' <CR> Jump  yy Copy Path  q/Esc Close ', footer_pos = 'center'
  })
  
  active_win = results_win
  active_buf = results_buf

  local prompt_title = file_filter and ' 🔍 Semantic Search (File) ' or ' 🔍 Semantic Search (Workspace) '
  local prompt_buf = vim.api.nvim_create_buf(false, true)
  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = 'editor', width = width, height = 1, row = row + height + 2, col = col,
    style = 'minimal', border = 'rounded', title = prompt_title, title_pos = 'left'
  })

  vim.bo[prompt_buf].buftype = 'prompt'
  vim.bo[prompt_buf].bufhidden = "wipe"
  vim.bo[prompt_buf].modified = false
  vim.fn.prompt_setprompt(prompt_buf, ' > ')
  vim.cmd('startinsert')

  local function close_ui()
    if vim.api.nvim_win_is_valid(results_win) then vim.api.nvim_win_close(results_win, true) end
    if vim.api.nvim_win_is_valid(prompt_win) then vim.api.nvim_win_close(prompt_win, true) end
  end

  vim.keymap.set('n', 'q', close_ui, { buffer = prompt_buf, noremap = true, silent = true })
  vim.keymap.set({'n', 'i'}, '<Esc>', close_ui, { buffer = prompt_buf, noremap = true, silent = true })
  vim.keymap.set('n', 'q', close_ui, { buffer = results_buf, noremap = true, silent = true })
  vim.keymap.set('n', '<Esc>', close_ui, { buffer = results_buf, noremap = true, silent = true })
  vim.keymap.set('n', '<CR>', function() jump_to_result(nil) end, { buffer = results_buf, noremap = true, silent = true })

  -- Setup keymaps for prompt if we are currently prompting
  local function setup_prompt_keys()
    vim.cmd('stopinsert')
    vim.keymap.set('n', 'y', function() 
      if M.pending_resolve then M.pending_resolve(true) end
      M.pending_resolve = nil
      M.app_state = "installing"
      pcall(vim.keymap.del, 'n', 'y', {buffer = prompt_buf})
      pcall(vim.keymap.del, 'n', 'n', {buffer = prompt_buf})
      vim.cmd('startinsert') 
    end, {buffer=prompt_buf, nowait=true})
    
    vim.keymap.set('n', 'n', function() 
      if M.pending_resolve then M.pending_resolve(false) end
      M.pending_resolve = nil
      M.app_state = "ready"
      close_ui()
    end, {buffer=prompt_buf, nowait=true})
  end

  if M.app_state == "prompt_install" then
     setup_prompt_keys()
  end

  local timer = nil
  local function stop_timer()
    if timer then timer:stop(); timer:close(); timer = nil end
  end

  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = prompt_buf,
    callback = function()
       vim.schedule(function() 
         if vim.api.nvim_get_current_win() ~= results_win then
           close_ui() 
         end
       end)
    end,
    once = true
  })

  math.randomseed(os.time())
  local bar_idx = 0
  local tip_idx = math.random(1, #tips)
  local frame = 1
  local local_ready_drawn = false
  local local_results_drawn = false

  -- GUI context passed down
  local ctx = {
    on_install_prompt = function(resolve, msg, submsg)
       M.app_state = "prompt_install"
       M.prompt_msg = msg or "  📦 Missing Python dependencies detected!"
       M.prompt_submsg = submsg or "  (faiss-cpu, numpy, ollama)"
       M.pending_resolve = resolve
       setup_prompt_keys()
    end,
    on_install_progress = function(msg)
       M.app_state = "installing"
       M.progress_msg = msg
    end,
    on_index_progress = function(msg)
       M.app_state = "indexing"
       M.progress_msg = msg
    end,
    on_error = function(msg)
       M.app_state = "ready"
       vim.notify("SemSearch: " .. msg, vim.log.levels.ERROR)
    end
  }

  timer = vim.loop.new_timer()
  timer:start(0, 100, vim.schedule_wrap(function()
    if not vim.api.nvim_win_is_valid(results_win) then return stop_timer() end

    if M.app_state == "prompt_install" then
      local lines = {
         "", M.prompt_msg or "  📦 Missing Python dependencies detected!", 
         M.prompt_submsg or "  (faiss-cpu, numpy, ollama)", "",
         "  Type 'y' to install automatically, or 'n' to cancel.", ""
      }
      pcall(vim.api.nvim_win_set_config, results_win, { title = ' ⚙️ Setup Required ' })
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)

    elseif M.app_state == "installing" or M.app_state == "indexing" then
      local bar = get_bouncing_bar(bar_idx, 20)
      bar_idx = bar_idx + 1
      local icon = M.app_state == "installing" and "📦" or "🚀"
      local lines = {
         "", "  " .. icon .. " " .. M.progress_msg, "  [" .. bar .. "]", "",
         "  " .. spinner_frames[frame] .. " " .. tips[tip_idx]
      }
      pcall(vim.api.nvim_win_set_config, results_win, { title = ' ⏳ Booting up... ' })
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
      frame = (frame % #spinner_frames) + 1

    elseif M.app_state == "searching" and M.search_start_time then
      local elapsed = (vim.loop.hrtime() - M.search_start_time) / 1e9
      local str = string.format("  %s Searching... (%.1fs)", spinner_frames[frame], elapsed)
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {str})
      frame = (frame % #spinner_frames) + 1
      
    elseif M.app_state == "ready" and not local_ready_drawn then
      local_ready_drawn = true
      local title_str = file_filter and ' 🎯 Semantic Search (File) ' or ' 🎯 Semantic Search (Workspace) '
      pcall(vim.api.nvim_win_set_config, results_win, { title = title_str })
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {"", "  ✅ Ready! Type a query below to semantic search.", "", "  💡 " .. tips[tip_idx]})
      if vim.api.nvim_get_current_win() == prompt_win then
         vim.cmd('startinsert')
      end
      
    elseif M.app_state == "results" and not local_results_drawn then
      local_results_drawn = true
      local lines = {}
      for _, res in ipairs(M.current_results) do
           local snip = tostring(res.snippet or ""):gsub("\n", " "):gsub("^%s*", ""):sub(1, 40)
           local file_path = vim.fn.fnamemodify(res.file, ":~:.")
           local func = res.func and res.func ~= "" and (" [" .. res.func .. "]") or ""
           table.insert(lines, string.format(" %2d%% │ %s:%s%s │ %s", res.score, file_path, res.line, func, snip))
        end
      if #lines == 0 then lines = {"  No results found."} end
      
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
      local scope_str = file_filter and "File" or "Workspace"
      pcall(vim.api.nvim_win_set_config, results_win, { title = ' 🎯 Semantic Search ' .. scope_str .. ' (' .. #M.current_results .. ' matches) ' })
      pcall(vim.api.nvim_win_set_cursor, results_win, {1, 0})
    end
  end))

  -- Initialize lazily
  if M.app_state == "pending" then
    index.init(function()
       M.app_state = "ready"
    end, ctx)
  elseif M.app_state == "results" then
    -- re-draw active results when opening
    local_results_drawn = false 
  end

  vim.fn.prompt_setcallback(prompt_buf, function(query)
    if not query or query == "" then 
      vim.cmd('startinsert'); return 
    end
    
    if M.app_state == "prompt_install" or M.app_state == "installing" or M.app_state == "indexing" then
      return
    end

    M.app_state = "searching"
    M.search_start_time = vim.loop.hrtime()
    local_ready_drawn = false -- wipe state

    index.search(query, { file_filter = file_filter }, function(results, err)
      vim.schedule(function()
        if err then
          vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {"  Error: " .. tostring(err)})
          M.app_state = "ready"
          return
        end

        M.current_results = results or {}
        M.app_state = "results"
        local_results_drawn = false
        
        vim.cmd('stopinsert')
        if vim.api.nvim_win_is_valid(results_win) then
            vim.api.nvim_set_current_win(results_win)
        end
      end)
    end, ctx)
  end)
end

return M
