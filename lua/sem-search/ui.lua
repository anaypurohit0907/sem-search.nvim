local config = require('sem-search.config')
local index = require('sem-search.index')

local M = {}

local spinner_frames = {'⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'}
local spinner_timer = nil

local function start_spinner_job(winid, start_time)
  local frame = 1
  spinner_timer = vim.loop.new_timer()
  spinner_timer:start(0, 100, vim.schedule_wrap(function()
    if not vim.api.nvim_win_is_valid(winid) then
      spinner_timer:stop()
      spinner_timer:close()
      return
    end
    
    local elapsed = (vim.loop.hrtime() - start_time) / 1e9
    local str = string.format("%s Searching... (%.1fs)", spinner_frames[frame], elapsed)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {str})
    frame = (frame % #spinner_frames) + 1
  end))
end

function M.show_loading()
  local bufnr = vim.api.nvim_create_buf(false, true)
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = 30, height = 1,
    row = math.floor((vim.o.lines - 1) / 2),
    col = math.floor((vim.o.columns - 30) / 2),
    style = 'minimal',
    border = 'rounded'
  })
  
  local start_time = vim.loop.hrtime()
  start_spinner_job(winid, start_time)
  return winid
end

function M.show_results(results, query)
  local bufnr = vim.api.nvim_create_buf(false, true)
  local ns = vim.api.nvim_create_namespace('sem-search')
  
  local lines = {}
  for _, res in ipairs(results) do
     -- mock rendering
     table.insert(lines, string.format("%s%%  %s:%s  %s", res.score, res.file, res.line, res.func))
     table.insert(lines, string.format("├─ %s", res.snippet:sub(1, 40):gsub("\n", " ")))
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  
  local winid = vim.api.nvim_open_win(bufnr, true, {
    relative = 'editor',
    width = 80, height = #lines + 3,
    row = math.floor((vim.o.lines - (#lines+3)) / 2),
    col = math.floor((vim.o.columns - 80) / 2),
    style = 'minimal',
    border = 'single',
    title = ' 🎯 Semantic Search Results (' .. #results .. ' matches) ',
    title_pos = 'center',
    footer = ' Navigation: <CR> Jump  <c-v> Vertical  yy Copy Path  q Close '
  })
  
  -- highlight groups mapping
  vim.api.nvim_buf_set_keymap(bufnr, 'n', 'q', '<cmd>bwipeout!<cr>', {noremap = true, silent = true})
  -- map yy, cr, d ...
end

function M.search()
  vim.ui.input({ prompt = '🔍 Semantic Search [ Workspace ]' }, function(query)
    if not query or query == "" then return end
    
    local load_win = M.show_loading()
    
    -- Mock execute search semantic logic...
    vim.defer_fn(function()
      if vim.api.nvim_win_is_valid(load_win) then
        vim.api.nvim_win_close(load_win, true)
      end
      
      M.show_results({
        { score = 92, file = "src/currency.go", line = 45, func = "to_inr_converter(" .. query .. ")", snippet = "return value * 83.25" }
      }, query)
    end, 200)
  end)
end

return M
