req_id = 0
callbacks = {}

local M = {}
function M.request(cmd, args, callback)
    req_id = req_id + 1
    callbacks[req_id] = callback
    local payload = vim.fn.json_encode({
      id = req_id,
      cmd = cmd,
      args = args or {}
    })
    print(payload)
end
M.request("search", {query = "test"})
M.request("search", {query = "test2"})
