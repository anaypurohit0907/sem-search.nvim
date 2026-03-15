# sem-search.nvim

 the most intuitive, beautiful semantic search Neovim has ever seen. 

## Features
- **Tree-sitter native**: Fast chunking & extraction.
- **Ollama + nomic-embed-text**: 100% local embedding models.
- **FAISS**: <200ms lightning-fast semantic queries in python.

## Installation (Lazy.nvim)

```lua
return {
  "anay/sem-search.nvim",
  dependencies = { "nvim-treesitter/nvim-treesitter" },
  opts = {
    keymap = { 
      search = '<leader>ss', 
      workspace_search = '<leader>sw', 
      setup = '<leader>uS', 
      reindex = '<leader>si' 
    },
    ollama_host = 'localhost:11434',
    embed_model = 'nomic-embed-text',
    max_results = 10,
    chunk_size = 10000,
    auto_index = true,
  },
}
```

## Commands
- `<leader>ss` - Semantic search within the current file
- `<leader>sw` - Semantic search across the entire workspace
- `<leader>si` - Manually update and reindex the workspace
- `<leader>uS` - SemSearch config (Settings)
- `:Semsetup` - First-time index setup / Reindex workspace
