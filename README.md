# sem-search.nvim

The most intuitive, beautiful, and **100% local** semantic search for Neovim. 

Stop grepping for exact strings. Start searching for **intent**. `sem-search.nvim` uses Ollama and FAISS to index your codebase locally, allowing you to find code using natural language (e.g., "where do we handle user authentication?" or "database connection logic").

---

## Quick Start

1. **Install Dependencies** (See below)
2. **Open a Project** in Neovim.
3. **Run `:Semsetup`** to begin the initial indexing.
4. **Search!** Use `<leader>sw` to search your entire workspace.

> [!IMPORTANT]  
> **Initial Indexing**: For large codebases (1,000+ chunks), the first index can take several minutes depending on your hardware. This is normal! We process code in parallel batches to be as fast as possible. Once indexed, subsequent updates are **incremental and nearly instant**.

---

## External Dependencies

This plugin is designed to be private and local. It requires the following tools installed on your system:

### 1. [Ollama](https://ollama.com/) (Required)
The engine that runs the embedding models locally.
- **Install**: `curl -fsSL https://ollama.com/install.sh | sh`
- **Model**: By default, we use `nomic-embed-text`. The plugin will prompt you to pull it automatically if it's missing.

### 2. Python 3.8+
Used for the high-performance FAISS vector search bridge. The plugin will automatically attempt to install the following Python packages via `pip` if they are missing:
- `faiss-cpu` (Vector search engine)
- `numpy` (Numerical processing)
- `ollama` (Python client)

---

## Installation

### [Lazy.nvim](https://github.com/folke/lazy.nvim) (Recommended)
```lua
{
  "anaypurohit0907/sem-search.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require('sem-search').setup({
      -- === Keymaps ===
      keymap = {
        search = '<leader>ss',           -- Semantic search in current buffer
        workspace_search = '<leader>sw', -- Search entire project
        setup = '<leader>uS',            -- Manage ignore patterns
        reindex = '<leader>si',          -- Trigger incremental reindex
      },

      -- === Ollama ===
      ollama_host = 'localhost:11434',     -- Ollama server address
      embed_model = 'nomic-embed-text',   -- Embedding model (nomic-embed-text recommended)

      -- === Search ===
      max_results = 10,                    -- Max results to return per search
      include_global_in_search = false,    -- Include cross-project results (GlobalKB)

      -- === Indexing ===
      chunk_size_lines = 50,              -- Lines per chunk (smaller = more granular)
      chunk_overlap_lines = 15,           -- Overlap between chunks (helps find boundary code)
      auto_index = true,                   -- Auto-reindex changed files on save
      batch_size = 100,                    -- Chunks per embedding batch (env: SEMSEARCH_BATCH_SIZE)
      max_workers = 8,                     -- Parallel embedding workers (env: SEMSEARCH_MAX_WORKERS, 0=auto)
      global_kb_auto_save = true,         -- Auto-save GlobalKB after adding chunks

      -- === Filtering ===
      ignore_enabled = true,              -- Enable/disable all ignore patterns
      ignore_patterns = {                 -- Glob-style patterns to skip during indexing
        "\\.git/",
        "node_modules/",
        "vendor/",
        "\\.venv/",
        "dist/",
        "build/",
        "docs/",
      },

      -- === UI ===
      colors = {
        score = 'DiagnosticHint',         -- Score highlight group
        path = 'String',                  -- File path highlight group
        func = 'Function',                -- Function/class name highlight group
      },
    })
  end
}
```

### [Packer.nvim](https://github.com/wbthomason/packer.nvim)
```lua
use {
  'anaypurohit0907/sem-search.nvim',
  requires = { 'nvim-lua/plenary.nvim' },
  config = function()
    require('sem-search').setup({})
  end
}
```

### [Vim-plug](https://github.com/junegunn/vim-plug)
```vim
Plug 'nvim-lua/plenary.nvim'
Plug 'anaypurohit0907/sem-search.nvim'

" Add this to your init.lua or in a lua block in init.vim
lua << EOF
require('sem-search').setup({})
EOF
```

---

## Default Keymaps

| Keymap | Action | Description |
| :--- | :--- | :--- |
| `<leader>ss` | **Search File** | Semantic search within the current buffer only. |
| `<leader>sw` | **Workspace** | Search the entire project. |
| `<leader>uS` | **Filters** | Manage and toggle your ignore patterns. |
| `<leader>si` | **Reindex** | Manually trigger an incremental update. |
| `:SemStatus` | **Health** | Check if your index is healthy and see chunk counts. |
| `:Semsetup`  | **Init** | Perform the first-time full workspace index. |

### Search Interface Keys

| Key | Action |
| :--- | :--- |
| `<C-i>` | **Toggle Filters** | Quickly turn all active ignore patterns ON/OFF. |
| `<CR>` | **Jump** | Go to the selected search result. |
| `q / Esc` | **Close** | Exit the search interface. |

---

## Features

- **Smart Filtering**: Configure `ignore_patterns` (like `node_modules/` or `docs/`) to keep your search results clean.
- **Filter Management Menu**: Press `<leader>uS` to open a menu where you can pick and choose which specific folders to ignore in real-time.
- **Auto-index on save**: Automatically and silently keeps your index up-to-date every time you save a file.
- **Incremental Indexing**: Only re-indexes files you've changed. Zero wasted CPU.
- **Parallel Batching**: Squeezes every bit of performance out of your local Ollama instance.
- **Atomic Saves**: Your index files are protected against corruption, even if Neovim crashes or is closed midway.
- **Smart UI**: Beautiful floating windows with real-time progress bars and code snippets.
- **Project Aware**: Automatically switches indexes when you change project directories in a single Neovim session.

---

## Troubleshooting

- **Search is "Infinite Loading"**: Ollama might be busy downloading a model or processing a large batch from another instance. Check `ollama ps` in your terminal.
- **No results**: Ensure you have run `:Semsetup` at least once in the project.
- **Corrupted index?**: Run `:SemStatus`. If it reports issues, simply run `:Semsetup` to wipe and rebuild safely.

```bash
# Manual check of your local indexes
ls -lh ~/.local/share/nvim/sem-search/
```
