local config = require("sem-search.config")
local index = require("sem-search.index")

local M = {}

-- Global UI State allowing users to close the window and re-open smoothly
M.app_state = "pending" -- pending, prompt_install, installing, indexing, ready, searching, results
M.progress_msg = ""
M.progress_pct = nil
M.pending_resolve = nil
M.current_results = {}
M.search_start_time = nil
M.ignore_enabled = config.options.ignore_enabled
if M.ignore_enabled == nil then
	M.ignore_enabled = true
end
M.pattern_states = {} -- pattern string -> boolean

local function get_active_patterns()
	local active = {}
	for _, p in ipairs(config.options.ignore_patterns or {}) do
		if M.pattern_states[p] ~= false then
			table.insert(active, p)
		end
	end
	return active
end

function M.show_filter_menu()
	local patterns = config.options.ignore_patterns or {}
	if #patterns == 0 then
		vim.notify("SemSearch: No ignore patterns configured.", vim.log.levels.WARN)
		return
	end

	local width = 50
	local height = #patterns + 2
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local buf = vim.api.nvim_create_buf(false, true)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = " SemSearch: Manage Filters ",
		title_pos = "center",
		footer = " <CR> Toggle  q/Esc Close ",
		footer_pos = "center",
	})

	local function redraw()
		local lines = {}
		for _, p in ipairs(patterns) do
			local status = M.pattern_states[p] ~= false and "[x]" or "[ ]"
			table.insert(lines, string.format("  %s %s", status, p))
		end
		table.insert(lines, "")
		table.insert(lines, "  Global Filter: " .. (M.ignore_enabled and "ENABLED" or "DISABLED"))
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	end

	redraw()

	local function toggle()
		local cursor = vim.api.nvim_win_get_cursor(win)
		local idx = cursor[1]
		if idx <= #patterns then
			local p = patterns[idx]
			M.pattern_states[p] = not (M.pattern_states[p] ~= false)
			redraw()
			if M.last_query and M.trigger_search then
				M.trigger_search(M.last_query)
			end
		elseif idx == #patterns + 2 then
			M.toggle_ignore()
			redraw()
		end
	end

	vim.keymap.set("n", "<CR>", toggle, { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("n", "q", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Esc>", function()
		vim.api.nvim_win_close(win, true)
	end, { buffer = buf, noremap = true, silent = true })
end

local spinner_frames = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
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

function M.cycle_result(dir)
	if not M.current_results or #M.current_results == 0 then
		return
	end
	M.active_res_idx = (M.active_res_idx or 1) + dir
	if M.active_res_idx > #M.current_results then
		M.active_res_idx = 1
	end
	if M.active_res_idx < 1 then
		M.active_res_idx = #M.current_results
	end

	local res = M.current_results[M.active_res_idx]
	if res and res.file then
		vim.cmd("edit " .. res.file)
		pcall(vim.api.nvim_win_set_cursor, 0, { res.line, 0 })
		vim.cmd("normal! zz")
		vim.notify(
			string.format(
				"SemSearch: Result %d/%d in %s",
				M.active_res_idx,
				#M.current_results,
				vim.fn.fnamemodify(res.file, ":t")
			),
			vim.log.levels.INFO
		)
	end
end

function M.exit_cycle_mode()
	M.cycling_active = false
	pcall(vim.keymap.del, "n", "<C-n>")
	pcall(vim.keymap.del, "n", "<C-p>")
	pcall(vim.keymap.del, "n", "<C-c>")
	vim.notify("SemSearch Cycle Mode Exit", vim.log.levels.INFO)
end

function M.toggle_ignore()
	M.ignore_enabled = not M.ignore_enabled
	vim.notify("SemSearch Filters: " .. (M.ignore_enabled and "ON" or "OFF"), vim.log.levels.INFO)
	if M.last_query and M.trigger_search then
		M.trigger_search(M.last_query)
	end
end

function M.setup_cycle_keybinds()
	if M.cycling_active then
		-- rebind if already active to ensure they didn't get overwritten
		vim.keymap.set("n", "<C-n>", function()
			M.cycle_result(1)
		end, { desc = "SemSearch Next" })
		vim.keymap.set("n", "<C-p>", function()
			M.cycle_result(-1)
		end, { desc = "SemSearch Prev" })
		vim.keymap.set("n", "<C-c>", function()
			M.exit_cycle_mode()
		end, { desc = "SemSearch Exit Mode" })
		return
	end
	M.cycling_active = true

	vim.notify("SemSearch Cycle Mode: <C-n> Next, <C-p> Prev, <C-c> Exit", vim.log.levels.INFO)

	vim.keymap.set("n", "<C-n>", function()
		M.cycle_result(1)
	end, { desc = "SemSearch Next" })
	vim.keymap.set("n", "<C-p>", function()
		M.cycle_result(-1)
	end, { desc = "SemSearch Prev" })
	vim.keymap.set("n", "<C-c>", function()
		M.exit_cycle_mode()
	end, { desc = "SemSearch Exit Mode" })
end

local function jump_to_result(split_cmd)
	if not active_win or not vim.api.nvim_win_is_valid(active_win) then
		return
	end
	local cursor_ok, cursor = pcall(vim.api.nvim_win_get_cursor, active_win)
	if not cursor_ok then
		return
	end

	local row = cursor[1]
	local res_idx = row
	local res = M.current_results[res_idx]

	if res and res.file then
		if M.close_ui then
			M.close_ui()
		else
			vim.cmd("q")
		end
		if split_cmd then
			vim.cmd(split_cmd)
		end
		vim.cmd("edit " .. res.file)
		pcall(vim.api.nvim_win_set_cursor, 0, { res.line, 0 })
		vim.cmd("normal! zz")

		M.active_res_idx = res_idx
		M.setup_cycle_keybinds()
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

	if M.app_state == "results" or M.app_state == "ready" then
		-- Don't clear M.current_results here, we might want to cycle through them
		-- Only clear when starting a new search
		M.app_state = "ready"
	end

	local current_file = vim.api.nvim_buf_get_name(0)
	if current_file ~= "" then
		local cwd = vim.fn.getcwd()
		if vim.startswith(current_file, cwd) then
			current_file = current_file:sub(#cwd + 2)
		end
	else
		current_file = nil
	end
	local file_filter = nil
	if not opts.workspace then
		file_filter = current_file
	end

	local width = 80
	local height = 15
	local row = math.floor((vim.o.lines - height) / 2)
	local col = math.floor((vim.o.columns - width) / 2)

	local results_buf = vim.api.nvim_create_buf(false, true)
	vim.bo[results_buf].bufhidden = "wipe"
	local results_title = file_filter and "  Sem-Search.nvim (File) " or "  Sem-Search.nvim (Workspace) "
	local results_win = vim.api.nvim_open_win(results_buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = row,
		col = col,
		style = "minimal",
		border = "rounded",
		title = results_title,
		title_pos = "center",
		footer = " <CR> Jump  <C-i> Toggle Filter  q/Esc Close ",
		footer_pos = "center",
	})

	active_win = results_win
	active_buf = results_buf

	local prompt_title = file_filter and "  Sem-Search (File) " or "  Sem-Search.nvim (Workspace) "
	local prompt_buf = vim.api.nvim_create_buf(false, true)
	local prompt_win = vim.api.nvim_open_win(prompt_buf, true, {
		relative = "editor",
		width = width,
		height = 1,
		row = row + height + 2,
		col = col,
		style = "minimal",
		border = "rounded",
		title = prompt_title,
		title_pos = "left",
	})

	vim.bo[prompt_buf].buftype = "prompt"
	vim.bo[prompt_buf].bufhidden = "wipe"
	vim.bo[prompt_buf].modified = false
	vim.fn.prompt_setprompt(prompt_buf, " > ")
	vim.cmd("startinsert")

	local function close_ui()
		if vim.api.nvim_win_is_valid(results_win) then
			vim.api.nvim_win_close(results_win, true)
		end
		if vim.api.nvim_win_is_valid(prompt_win) then
			vim.api.nvim_win_close(prompt_win, true)
		end
	end
	M.close_ui = close_ui

	vim.keymap.set("n", "q", close_ui, { buffer = prompt_buf, noremap = true, silent = true })
	vim.keymap.set({ "n", "i" }, "<Esc>", close_ui, { buffer = prompt_buf, noremap = true, silent = true })
	vim.keymap.set("n", "q", close_ui, { buffer = results_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<Esc>", close_ui, { buffer = results_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<CR>", function()
		jump_to_result(nil)
	end, { buffer = results_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<C-n>", function()
		if vim.api.nvim_win_is_valid(prompt_win) then
			vim.api.nvim_set_current_win(prompt_win)
			vim.cmd("startinsert")
		end
	end, { buffer = results_buf, noremap = true, silent = true })

	vim.keymap.set({ "i", "n" }, "<C-i>", function()
		M.toggle_ignore()
	end, { buffer = prompt_buf, noremap = true, silent = true })
	vim.keymap.set("n", "<C-i>", function()
		M.toggle_ignore()
	end, { buffer = results_buf, noremap = true, silent = true })

	-- Setup keymaps for prompt if we are currently prompting
	local function setup_prompt_keys()
		vim.cmd("stopinsert")
		vim.keymap.set("n", "y", function()
			if M.pending_resolve then
				M.pending_resolve(true)
			end
			M.pending_resolve = nil
			M.app_state = "installing"
			pcall(vim.keymap.del, "n", "y", { buffer = prompt_buf })
			pcall(vim.keymap.del, "n", "n", { buffer = prompt_buf })
			vim.cmd("startinsert")
		end, { buffer = prompt_buf, nowait = true })

		vim.keymap.set("n", "n", function()
			if M.pending_resolve then
				M.pending_resolve(false)
			end
			M.pending_resolve = nil
			M.app_state = "ready"
			close_ui()
		end, { buffer = prompt_buf, nowait = true })
	end

	if M.app_state == "prompt_install" then
		setup_prompt_keys()
	end

	local timer = nil
	local function stop_timer()
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
		once = true,
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
			M.prompt_msg = msg or "   Missing Python dependencies detected!"
			M.prompt_submsg = submsg or "  (faiss-cpu, numpy, ollama)"
			M.pending_resolve = resolve
			setup_prompt_keys()
		end,
		on_install_progress = function(msg, pct)
			M.app_state = "installing"
			M.progress_msg = msg
			M.progress_pct = pct
		end,
		on_index_progress = function(msg, pct)
			M.app_state = "indexing"
			M.progress_msg = msg
			M.progress_pct = pct
		end,
		on_error = function(msg)
			local_ready_drawn = false
			M.error_msg = msg
			M.app_state = "error"
			vim.notify("SemSearch: " .. msg, vim.log.levels.ERROR)
		end,
	}

	M.last_file_filter = file_filter
	M.last_ctx = ctx

	timer = vim.loop.new_timer()
	timer:start(
		0,
		100,
		vim.schedule_wrap(function()
			if not vim.api.nvim_win_is_valid(results_win) then
				return stop_timer()
			end

			if M.app_state == "prompt_install" then
				local lines = {
					"",
					M.prompt_msg or "   Missing Python dependencies detected!",
					M.prompt_submsg or "  (faiss-cpu, numpy, ollama)",
					"",
					"  Type 'y' to install automatically, or 'n' to cancel.",
					"",
				}
				pcall(vim.api.nvim_win_set_config, results_win, { title = "  Setup Required " })
				vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
			elseif M.app_state == "installing" or M.app_state == "indexing" then
				local bar
				if M.progress_pct then
					local bar_width = 30
					local filled = math.floor((M.progress_pct / 100) * bar_width)
					bar = string.rep("#", filled)
						.. string.rep("-", bar_width - filled)
						.. string.format(" %d%%", M.progress_pct)
				else
					bar = get_bouncing_bar(bar_idx, 20)
					bar_idx = bar_idx + 1
				end

				local icon = M.app_state == "installing" and "INSTALL" or "INDEX"
				local lines = {
					"",
					"  " .. icon .. " " .. M.progress_msg,
					"  [" .. bar .. "]",
					"",
					"  " .. spinner_frames[frame] .. " " .. tips[tip_idx],
				}
				pcall(vim.api.nvim_win_set_config, results_win, { title = "  Booting up... " })
				vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
				frame = (frame % #spinner_frames) + 1
			elseif M.app_state == "searching" and M.search_start_time then
				local elapsed = (vim.loop.hrtime() - M.search_start_time) / 1e9
				local str = string.format("  %s Searching... (%.1fs)", spinner_frames[frame], elapsed)
				vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, { str })
				frame = (frame % #spinner_frames) + 1
			elseif M.app_state == "error" and not local_ready_drawn then
				local_ready_drawn = true
				pcall(vim.api.nvim_win_set_config, results_win, { title = "  Error!! " })
				vim.api.nvim_buf_set_lines(
					results_buf,
					0,
					-1,
					false,
					{ "", "  " .. tostring(M.error_msg or "Unknown error"), "", "  Press Enter to try again." }
				)
				if vim.api.nvim_get_current_win() == prompt_win then
					vim.cmd("startinsert")
				end
			elseif M.app_state == "ready" and not local_ready_drawn then
				local_ready_drawn = true
				local title_str = file_filter and "  Sem-Search.nvim (File) " or "  Sem-Search.nvim (Workspace) "
				pcall(vim.api.nvim_win_set_config, results_win, { title = title_str })
				vim.api.nvim_buf_set_lines(
					results_buf,
					0,
					-1,
					false,
					{ "", " Ready! Type a query below to semantic search." }
				)
				if vim.api.nvim_get_current_win() == prompt_win then
					vim.cmd("startinsert")
				end
			elseif M.app_state == "results" and not local_results_drawn then
				local_results_drawn = true
				local lines = {}
				local highlights = {}
				local ns_id = vim.api.nvim_create_namespace("sem_search_hl")

				for i, res in ipairs(M.current_results) do
					local snip = tostring(res.snippet or ""):gsub("\n", " "):gsub("\r", ""):gsub("^%s*", "")
					local file_path = vim.fn.fnamemodify(res.file, ":~:.")
					local func = res.func and res.func ~= "" and (" [" .. res.func .. "]") or ""

					local score_num = tonumber(res.score) or 0
					local score_hl = "DiagnosticError"
					if score_num >= 80 then
						score_hl = "DiagnosticOk"
					elseif score_num >= 50 then
						score_hl = "DiagnosticWarn"
					end

					local score_str = string.format(" %3d%% ", score_num)
					local file_str = string.format("│ %s:%s%s ", file_path, res.line, func)

					local prefix = score_str .. file_str .. "│ "
					local prefix_len = vim.fn.strdisplaywidth(prefix)
					local avail_len = math.max(0, width - prefix_len - 1)

					if #snip > avail_len then
						snip = snip:sub(1, math.max(0, avail_len - 3)) .. "..."
					elseif #snip < avail_len then
						snip = snip .. string.rep(" ", avail_len - #snip)
					end

					table.insert(lines, prefix .. snip)

					table.insert(highlights, {
						line = i - 1,
						score_hl = score_hl,
						score_end = #score_str,
						file_start = #score_str + 3,
						file_end = #score_str + 3 + #file_path + 1 + #(tostring(res.line)),
						func_start = func ~= "" and (#score_str + 3 + #file_path + 1 + #(tostring(res.line)) + 2)
							or nil,
						func_end = func ~= "" and (#score_str + 3 + #file_path + 1 + #(tostring(res.line)) + #func)
							or nil,
						snip_start = #prefix,
					})
				end
				if #lines == 0 then
					lines = { "  No results found." }
				end

				vim.api.nvim_buf_set_lines(results_buf, 0, -1, false, lines)
				vim.api.nvim_buf_clear_namespace(results_buf, ns_id, 0, -1)

				if #M.current_results > 0 then
					for _, h in ipairs(highlights) do
						vim.api.nvim_buf_add_highlight(results_buf, ns_id, h.score_hl, h.line, 0, h.score_end)
						vim.api.nvim_buf_add_highlight(
							results_buf,
							ns_id,
							"Directory",
							h.line,
							h.file_start,
							h.file_end
						)
						if h.func_start then
							vim.api.nvim_buf_add_highlight(
								results_buf,
								ns_id,
								"Function",
								h.line,
								h.func_start,
								h.func_end
							)
						end
						vim.api.nvim_buf_add_highlight(results_buf, ns_id, "Comment", h.line, h.snip_start, -1)
					end
				end

				local scope_str = file_filter and "File" or "Workspace"
				pcall(
					vim.api.nvim_win_set_config,
					results_win,
					{ title = "  Sem-Search.nvim " .. scope_str .. " (" .. #M.current_results .. " matches) " }
				)
				pcall(vim.api.nvim_win_set_cursor, results_win, { 1, 0 })
			end
		end)
	)

	-- Initialize lazily
	if M.app_state == "pending" then
		index.init(function()
			M.app_state = "ready"
		end, ctx)
	elseif M.app_state == "results" then
		-- re-draw active results when opening
		local_results_drawn = false
	end

	local function do_search(query)
		if not query or query == "" then
			vim.cmd("startinsert")
			return
		end

		if M.app_state == "prompt_install" or M.app_state == "installing" or M.app_state == "indexing" then
			return
		end

		M.last_query = query
		M.app_state = "searching"
		M.search_start_time = vim.loop.hrtime()
		local_ready_drawn = false -- wipe state
		local_results_drawn = false -- allow redraw

		index.search(query, {
			file_filter = file_filter,
			ignore_patterns = M.ignore_enabled and get_active_patterns() or nil,
		}, function(results, err)
			vim.schedule(function()
				if err then
					M.error_msg = err
					M.app_state = "error"
					local_ready_drawn = false
					return
				end

				M.current_results = results or {}
				M.app_state = "results"
				local_results_drawn = false

				vim.cmd("stopinsert")
				if vim.api.nvim_win_is_valid(results_win) then
					vim.api.nvim_set_current_win(results_win)
				end
			end)
		end, ctx)
	end
	M.trigger_search = do_search

	vim.fn.prompt_setcallback(prompt_buf, do_search)
end

return M
