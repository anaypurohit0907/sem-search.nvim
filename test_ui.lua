vim.opt.rtp:append(".")
require("sem-search").setup()
local ui = require("sem-search.ui")

ui.search()
ui.current_results = {{score=100, file="foo.lua", line=1, snippet="hello"}}
ui.app_state = "results"
ui.close_ui()

ui.search()

vim.api.nvim_command("sleep 500m")

-- Simulate typing and pressing Enter in the prompt buffer
local prompt_buf = vim.api.nvim_get_current_buf()
vim.api.nvim_feedkeys("inew query\n", "tx", false)

vim.api.nvim_command("sleep 500m")
print(ui.app_state)
