# sem-search.nvim — Agent Notes

## Architecture

- **Lua plugin** (`lua/sem-search/*.lua`): Entry via `init.lua`, config in `config.lua`, indexing in `index.lua`, Python IPC in `faiss.lua`, UI in `ui.lua`, code chunking in `chunker.lua`
- **Python server** (`python/faiss_server.py`): FAISS vector index + Ollama embeddings, communicates via JSON lines on stdin/stdout

## Dependencies (runtime, auto-installed)

- Ollama running locally (`localhost:11434`), default model `nomic-embed-text`
- Python packages: `faiss-cpu`, `numpy`, `ollama` (plugin auto-pulls missing model and pip-installs packages on first run)

## Index Storage

`~/.local/share/nvim/sem-search/<first_10_chars_of_sha256(cwd)>/`

Two files per project: `.index` (FAISS binary) and `.meta.json` (chunk metadata).

Global KB: `~/.local/share/nvim/sem-search/global/` (global.index, global.meta.json, global.hashes.json)

## File Discovery

1. `git ls-files` if `.git` dir + git executable
2. `rg --files --hidden -g '!.git/'` if ripgrep available
3. `find . -type f` fallback

Excluded: `.git/`, `.png`, `.jpg`, files without extensions (index.lua:36).

## Code Chunking

- Chunk size: 50 lines, overlap: 15 lines (`chunker.lua:42-43`)
- Detects top-level functions/classes only (regex on chunker.lua:18-24). Nested functions not labeled.
- Embed prefix: `search_document: ` for nomic-embed-text

## Adaptive Batching

- Config: `batch_size` (default 100), `max_workers` (default 8) — `config.lua`
- Python auto-detects CPU cores via `multiprocessing.cpu_count()`
- Workers: `min(8, max(2, cpu_count))` by default; capped to `min(n_batches, effective_workers)`
- Batch size: 200 default if config unset; capped at 500
- Env var overrides: `SEMSEARCH_BATCH_SIZE`, `SEMSEARCH_MAX_WORKERS` (set 0 for auto)
- Three-tier override: config > env var > auto-detected defaults

## Python Server Behavior

- Batch embedding: adaptive (see above)
- Search embeds with `search_query: ` prefix for nomic
- Score threshold: reject results < 0.3 similarity (faiss_server.py:319)
- BM25 keyword fallback + RRF fusion (60:40 semantic:keyword blend) — faiss_server.py:298+
- GlobalKB singleton for cross-project deduplication via SHA256 content hash

## Key Implementation Quirks

- `setup()` must be called manually by user (no auto-setup in plugin loader)
- `init.lua:setup_done` guard prevents double-init
- faiss.lua resolves its own script path via `debug.getinfo(1, "S").source` (line 139)
- `index.is_indexing` is a module-level flag, not per-project
- BM25 computed fresh on every search (no pre-indexing)
- GlobalKB deduplicates by content hash (first 16 hex chars of SHA256 of chunk text)
- Cross-project search via `cross_search` command → `M.cross_search()` in faiss.lua

## Workflow
- After finishing any work session, check `plan.md` and update it to mark what was done vs left.
