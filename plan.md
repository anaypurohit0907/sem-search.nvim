# sem-search.nvim — Implementation Plan

## Overview

Three goals: (1) faster/lighter embedding, (2) better search, (3) multi-project support.

---

## Phase 1: Faster & Lighter Embedding

### 1a. Adaptive Batching
- [x] Configurable batch size and worker count via config option (`config.lua: batch_size`, `max_workers`)
- [x] Auto-detect CPU cores via `multiprocessing.cpu_count()`, scale workers accordingly
- [x] Env var overrides: `SEMSEARCH_BATCH_SIZE`, `SEMSEARCH_MAX_WORKERS` (set 0 to use auto)
- [x] CodeIndex stores per-instance `batch_size` and `max_workers_cfg`, passed from Lua config

### 1b. Smart Chunking
- [x] Symbol-aware chunk boundaries (align to function/class definitions)
- [x] Header stripping: embed pure code, prepend File/Context at search time (chunker.lua `get_text()`)
- [x] Chunk-level deduplication via SHA256 hash of code_text
- [ ] Language-aware block detection (nested scope, decorators, etc.)

### 1c. Ollama Optimizations
- [x] Persistent ollama.Client singleton (`_get_client()`)
- [x] Batch size: 25 → 100, workers: 2 → 4-8
- [x] warmup command (send dummy embed on server init)
- [ ] GPU detection and adaptive batch sizing

### 1d. Background Warmup
- [x] Pre-warm Ollama 1s after plugin setup() via vim.defer_fn
- [ ] Lazy GlobalKB load on first cross-search (GlobalKB is lazy but still loads state on init)

---

## Phase 2: Better Search

### 2a. Parallel Search Pipeline
- [x] BM25 keyword fallback (BM25 class, computed per search)
- [x] 60/40 semantic:BM25 weighted fusion
- [x] RRF fusion for rank combination
- [ ] Parallel: thread Ollama embed and BM25 scoring simultaneously
- [ ] Adaptive fusion weights (keyword-heavy vs conceptual queries)

### 2b. Result Quality
- [ ] Sub-chunk ranking: find exact best line within chunk, report that line (partial — find_best_line does this but only for code_text, not the full text with headers)
- [x] Near-duplicate deduplication via SHA256 hash (chunker.lua seen_hashes)
- [ ] Adaptive score threshold (percentile-based instead of hardcoded 0.3)
- [ ] Cross-encoder re-ranking (optional, OOM risk)

### 2c. Query Understanding
- [ ] Query type detection (exact match / conceptual / hybrid)
- [ ] Query expansion for short queries (<3 tokens)

---

## Phase 3: Multi-Project Support

### 3a. GlobalKB Polishing
- [x] GlobalKB singleton with persistent storage (global.json + global.index)
- [x] SHA256 content hash deduplication (16 hex chars)
- [x] Atomic multi-file writes (single json + faiss, both via .tmp then rename)
- [x] Scheduled background saves (5s debounce via threading.Timer)
- [ ] GlobalKB max size with LRU eviction or project ownership map
- [ ] Full 64-char SHA256 hash (upgrade from 16-char)

### 3b. Hash Lookup Before Embedding
- [ ] On update_delta: check GlobalKB hash first, retrieve vector if exists, skip Ollama call
- [ ] Backfill existing project indexes into GlobalKB on first run

### 3c. Cross-Project Search UX
- [x] cross_search command + M.cross_search() Lua API
- [x] global_stats command + M.global_stats() Lua API
- [ ] Toggle key (<C-g>) in search UI to include/exclude global results
- [x] Config option: include_global_in_search (default false)
- [ ] Mixed results with [@global] source label in UI
- [ ] RRF fusion of local + global results

### 3d. Project Management
- [ ] :SemGlobalStats — chunk count, storage (partially done via global_stats command)
- [ ] :SemGlobalClear — wipe with confirmation
- [ ] :SemGlobalPrune — remove stale entries

---

## Implementation Order

| Priority | Item | Status |
|----------|------|--------|
| P0 | Phase 1c (Ollama keepalive, warmup, workers) | Done |
| P0 | Phase 3a (Atomic GlobalKB writes, scheduled saves) | Done |
| P0 | Phase 1b (Smart chunking, header strip, dedup) | Done |
| P0 | Phase 1d (Lua-side warmup on setup) | Done |
| P1 | Phase 2a (Parallel BM25+semantic) | Partial |
| P1 | Phase 2b (Sub-chunk ranking, dedup) | Partial |
| P2 | Phase 3b (Hash lookup before embed) | Pending |
| P2 | Phase 3c (Cross-project UI: toggle, mixed results) | Partial |
| P3 | Phase 2c (Query understanding) | Pending |
| P0 | Phase 1a (Adaptive batching: config, CPU auto-detect, env vars) | Done |

---

## Risks

1. **GlobalKB unbounded growth**: No eviction. 1M chunks × 768 dims × 4B = ~2.4GB. Needs LRU or project ownership.
2. **Hash collision (16 hex)**: 2^64 space — acceptable but document risk.
3. **BM25 rebuild on every search**: Tokenizes all chunks per search. Needs caching (BM25 object per CodeIndex, invalidated on delta).
4. **GlobalKB save blocking**: Thread-safe via Timer, but save() writes two files. Acceptable.
5. **project index stores vectors, not GlobalKB refs**: kept_vectors reconstructed from local index. If GlobalKB is source of truth, project rebuild unnecessary.
6. **chunker.lua get_text() O(n²) in loop**: Originally passed raw_chunks table + chunk, looping to find the chunk. Fixed: now `get_text(chunk)` takes single chunk — O(1) per chunk.