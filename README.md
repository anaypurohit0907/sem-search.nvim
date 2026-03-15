# sem-search.nvim

Build the most intuitive, beautiful semantic search Neovim has ever seen. 

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
    keymap = { search = '<leader>ss', setup = '<leader>uS' },
    ollama_host = 'localhost:11434',
    embed_model = 'nomic-embed-text',
    max_results = 10,
    chunk_size = 10000,
    auto_index = true,
  },
}
```

## Commands
- `<leader>ss` - Open search input window
- `:Semetup` - First-time index setup.
- `<leader>si` - Manually update workspace index.
