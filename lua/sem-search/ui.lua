local config = require('sem-search.config')
local index = require('sem-search.index')

local M = {}

local spinner_frames = {'⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'}
local current_results = {}
local active_win = nil
local active_buf = nil

local function jump_to_result(split_cmd)
  local row = vim.api.nvim_win_get_cursor(active_win)[1]
  -- results take 2 lines per match: index 1 and 2 = match 1, 3 and 4 = match 2
  local res_idx = math.floor((row + 1) / 2)
  local res = current_results[res_idx]

  if res and res.file then
    -- close UI
    vim.cmd('q')
    
    if split_cmd then vim.cmd(split_cmd) end
    vim.cmd("edit " .. res.file)
    vim.api.nvim_win_set_cursor(0, {res.line, 0})
    vim.cmd("normal! zz")
  end
end

function M.search()
  local width = 80
  local height = 15
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local results_buf = vim.api.nvim_create_buf(false, true)
  local results_win = vim.api.nvim_open_win(results_buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = row,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' 🎯 Semantic Search Results ',
    title_pos = 'center',
    footer = ' <CR> Jump  <c-v> VSplit  <c-x> Split  yy Copy Path  q/Esc Close ',
    footer_pos = 'center'
  })
  
  active_win = results_win
  active_buf = results_buf

  local prompt_buf = vim.api.nvim_create_buf(false, true)
  local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
    relative = 'editor',
    width = width,
    height = 1,
    row = row + height + 2,
    col = col,
    style = 'minimal',
    border = 'rounded',
    title = ' 🔍 Semantic Search ',
    title_pos = 'left'
  })

  vim.bo[prompt_buf].buftype = 'prompt'
  vim.fn.prompt_setprompt(prompt_buf, ' > ')
  vim.cmd('startinsert')

  local function close_ui()
    if vim.api.nvim_win_is_valid(results_win) then vim.api.nvim_win_close(results_win, true) end
    if vim.api.nvim_win_is_valid(prompt_win) then vim.api.nvim_win_close(prompt_win, true) end
  end

  -- Keys for prompt
  vim.keymap.set('n', 'q', close_ui, { buffer = prompt_buf, noremap = true, silent = true })
  vim.keymap.set({'n', 'i'}, '<Esc>', close_ui, { buffer = prompt_buf, noremap = true, silent = true })
  
  -- Keys for results
  vim.keymap.set('n', 'q', close_ui, { buffer = results_buf, noremap = true, silent = true })
  vim.keymap.set('n', '<Esc>', close_ui, { buffer = results_buf, noremap = true, silent = true })
  vim.keymap.set('n', '<CR>', function() jump_to_result(nil) end, { buffer = results_buf, noremap = true, silent = true })
  vim.keymap.set('n', '<C-v>', function() jump_to_result("vsplit") end, { buffer = results_buf, noremap = true, silent = true })
  vim.keymap.set('n', '<C-x>', function() jump_to_result("split") end, { buffer = results_buf, noremap = true, silent = true })

  local timer = nil
  local function stop_spinner()
    if timer then
      timer:stop()
      timer:close()
      timer = nil
    end
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

  -- Start initializing background process if not already started
  index.init()

  vim.fn.prompt_setcallback(prompt_buf, function(query)
    if not query or query == "" then 
      vim.cmd('startinsert')
      return 
    end
    
    vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {})
    local frame = 1
    local start_time = vim.loop.hrtime()
    
    stop_spinner()
    timer = vim.loop.new_timer()
    timer:start(0, 100, vim.schedule_wrap(function()
      if not vim.api.nvim_win_is_valid(results_win) then return stop_spinner() end
      local elapsed = (vim.loop.hrtime() - start_time) / 1e9
      local str = string.format("  %s Searching... (%.1fs)", spinner_frames[frame], elapsed)
      vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {str})
      frame = (frame % #spinner_frames) + 1
    end))

    index.search(query, function(results, err)
      vim.schedule(function()
        stop_spinner()
        if not vim.api.nvim_win_is_valid(results_win) then return end
        
        if err then
          vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {"  Error: " .. tostring(err)})
          return
        end
        
        if not results or #results == 0 then
          vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, {"  No results found."})
          return
        end

        current_results = results
        local lines = {}
        for _, res in ipairs(results) do
           table.insert(lines, string.format(" %d%%  %s:%s  %s", res.score, res.file, res.line, res.func))
           local snip = tostring(res.snippet or ""):gsub("\n", " "):sub(1, 60)
           table.insert(lines, string.format(" ├─ %s", snip))
        end

        vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
        vim.api.nvim_win_set_config(results_win, { title = ' 🎯 Semantic Search Results (' .. #results .. ' matches) ' })
        
        vim.api.nvim_set_current_win(results_win)
        vim.cmd('stopinsert')
        -- disable highlight search visually locally for cleaner look
        vim.api.nvim_win_set_cursor(results_win, {1, 0})
      end)
    end)
  end)
end

return M
