local M = {}

-- mock python process communication
function M.reindex()
  print("Building index... (mocked)")
  -- call python script to build index using faiss_server.py
end

return M
