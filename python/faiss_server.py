import re
import sys
import json
import os
import faiss
import numpy as np
import ollama
from concurrent.futures import ThreadPoolExecutor, as_completed
import threading
import math
import hashlib
import multiprocessing

_client = None

_SEMSEARCH_BATCH_SIZE = int(os.environ.get('SEMSEARCH_BATCH_SIZE', '100'))
_SEMSEARCH_MAX_WORKERS = int(os.environ.get('SEMSEARCH_MAX_WORKERS', '0'))
_CPU_COUNT = multiprocessing.cpu_count() or 4

def _effective_workers(n_batches, config_workers):
    if config_workers > 0:
        capped = min(config_workers, _CPU_COUNT)
    else:
        capped = min(8, max(2, _CPU_COUNT))
    return min(capped, n_batches)

def _effective_batch_size(config_batch):
    if config_batch > 0:
        return min(config_batch, 500)
    return 200

def _get_client():
    global _client
    if _client is None:
        _client = ollama.Client()
    return _client

def _content_hash(text):
    return hashlib.sha256(text.encode('utf-8')).hexdigest()[:16]

def _tokenize(text):
    return [t.lower() for t in re.findall(r'[a-zA-Z0-9_]+', text.lower())]

def find_best_line(query, code_text):
    if not code_text:
        return 0
    query_terms = [t.lower() for t in re.findall(r'[a-zA-Z0-9_]+', query)]
    if not query_terms:
        return 0

    stop_words = {'and', 'the', 'for', 'that', 'this', 'with', 'from', 'have', 'has', 'function', 'local', 'return', 'end', 'then', 'else', 'elseif'}
    filtered_terms = [t for t in query_terms if len(t) > 2 and t not in stop_words]
    if not filtered_terms:
        filtered_terms = query_terms

    lines = code_text.split('\n')
    best_idx = 0
    best_score = -1
    for i, line in enumerate(lines):
        line_lower = line.lower()
        score = 0
        for term in filtered_terms:
            if term in line_lower:
                score += 1
                if re.search(r'\b' + re.escape(term) + r'\b', line_lower):
                    score += 1
            elif term.endswith('s') and term[:-1] in line_lower:
                score += 0.5
            elif term.endswith('ing') and term[:-3] in line_lower:
                score += 0.5
            elif term.endswith('ed') and term[:-2] in line_lower:
                score += 0.5
        if score > best_score:
            best_score = score
            best_idx = i
    return best_idx if best_score > 0 else 0

class GlobalKB:
    _instance = None

    @classmethod
    def get(cls, base_path=None):
        if cls._instance is None:
            cls._instance = cls(base_path)
        return cls._instance

    def __init__(self, base_path=None):
        if base_path is None:
            base_path = os.path.join(os.path.expanduser("~"), ".local", "share", "nvim", "sem-search", "global")
        self.base_path = base_path
        self.index_file = os.path.join(base_path, "global.index")
        self.state_file = os.path.join(base_path, "global.json")
        self._save_timer = None

        self.hash_to_idx = {}
        self.idx_to_hash = {}
        self.chunks = []
        self.index = faiss.IndexFlatIP(768)
        self._load()

    def _load(self):
        if os.path.exists(self.state_file):
            try:
                with open(self.state_file, 'r') as f:
                    state = json.load(f)
                self.chunks = state.get('chunks', [])
                self.hash_to_idx = state.get('hash_to_idx', {})
                self.idx_to_hash = {int(k): v for k, v in state.get('idx_to_hash', {}).items()}
            except Exception:
                pass

        if os.path.exists(self.index_file):
            try:
                self.index = faiss.read_index(self.index_file)
            except Exception:
                pass

    def save(self):
        os.makedirs(self.base_path, exist_ok=True)
        tmp_json = self.state_file + ".tmp"
        tmp_index = self.index_file + ".tmp"

        state = {
            'chunks': self.chunks,
            'hash_to_idx': self.hash_to_idx,
            'idx_to_hash': {str(k): v for k, v in self.idx_to_hash.items()},
            'vector_count': int(self.index.ntotal)
        }

        try:
            faiss.write_index(self.index, tmp_index)
            with open(tmp_json, 'w') as f:
                json.dump(state, f)
            os.replace(tmp_index, self.index_file)
            os.replace(tmp_json, self.state_file)
        except Exception as e:
            for f in [tmp_json, tmp_index]:
                if os.path.exists(f):
                    os.remove(f)
            raise e

    def schedule_save(self):
        if self._save_timer is not None:
            return
        self._save_timer = threading.Timer(5.0, self._flush_save)

    def _flush_save(self):
        self._save_timer = None
        self.save()

    def lookup_or_store(self, chunk_text, chunk_meta, model="nomic-embed-text"):
        h = _content_hash(chunk_text)
        if h in self.hash_to_idx:
            return self.hash_to_idx[h], True

        prefix = "search_document: " if "nomic-embed-text" in model else ""
        try:
            client = _get_client()
            res = client.embed(model=model, input=[prefix + chunk_text])
            vec = np.array(res['embeddings'], dtype='float32')
            faiss.normalize_L2(vec)
        except Exception:
            return None, False

        idx = self.index.ntotal
        self.index.add(vec)
        self.hash_to_idx[h] = idx
        self.idx_to_hash[idx] = h
        self.chunks.append(chunk_meta)
        self.schedule_save()
        return idx, False

    def get_vector(self, idx):
        if 0 <= idx < self.index.ntotal:
            return self.index.reconstruct(idx)
        return None

    def ntotal(self):
        return self.index.ntotal

    def clear(self):
        self.chunks = []
        self.hash_to_idx = {}
        self.idx_to_hash = {}
        self.index = faiss.IndexFlatIP(768)

class BM25:
    def __init__(self, chunks, k1=1.5, b=0.75):
        self.chunks = chunks
        self.k1 = k1
        self.b = b
        self.doc_tokens = [self._tokens(c) for c in chunks]
        self.N = len(self.doc_tokens)
        self.avgdl = sum(len(d) for d in self.doc_tokens) / max(self.N, 1)
        self.doc_freqs = {}
        for doc in self.doc_tokens:
            for term in set(doc):
                self.doc_freqs[term] = self.doc_freqs.get(term, 0) + 1
        self.idf = {}
        for term, df in self.doc_freqs.items():
            self.idf[term] = math.log((self.N - df + 0.5) / (df + 0.5) + 1)

    def _tokens(self, chunk):
        return _tokenize(chunk.get('code_text', '') or chunk.get('text', ''))

    def score(self, query):
        q_tokens = _tokenize(query)
        scores = []
        for doc in self.doc_tokens:
            score = 0.0
            dl = len(doc)
            term_freqs = {}
            for t in doc:
                term_freqs[t] = term_freqs.get(t, 0) + 1
            for q in q_tokens:
                if q not in term_freqs:
                    continue
                tf = term_freqs[q]
                idf = self.idf.get(q, 0)
                score += idf * (tf * (self.k1 + 1)) / (tf + self.k1 * (1 - self.b + self.b * dl / max(self.avgdl, 1)))
            scores.append(score)
        return scores

class CodeIndex:
    def __init__(self, index_path, batch_size=None, max_workers=None):
        self.index_path = index_path
        self.index_file = index_path + ".index"
        self.meta_file = index_path + ".meta.json"
        self.batch_size = batch_size if batch_size and batch_size > 0 else _effective_batch_size(_SEMSEARCH_BATCH_SIZE)
        self.max_workers_cfg = max_workers if max_workers and max_workers > 0 else _SEMSEARCH_MAX_WORKERS

        self.chunks = []
        if os.path.exists(self.index_file):
            try:
                self.index = faiss.read_index(self.index_file)
                if os.path.exists(self.meta_file):
                    with open(self.meta_file, 'r') as f:
                        self.chunks = json.load(f)
            except Exception as e:
                sys.stderr.write(f"Warning: Failed to load index, starting fresh: {str(e)}\n")
                self.index = faiss.IndexFlatIP(768)
                self.chunks = []
        else:
            self.index = faiss.IndexFlatIP(768)

    def add_chunks(self, chunks, model="nomic-embed-text", req_id=None, batch_size=None, max_workers=None):
        if not chunks:
            return

        batch_size = batch_size or self.batch_size
        batches = [chunks[i : i + batch_size] for i in range(0, len(chunks), batch_size)]
        n_workers = _effective_workers(len(batches), max_workers if max_workers and max_workers > 0 else self.max_workers_cfg)

        def embed_batch(idx):
            batch = batches[idx]
            prefix = "search_document: " if "nomic-embed-text" in model else ""
            inputs = [prefix + str(c['text']) for c in batch]
            client = _get_client()
            res = client.embed(model=model, input=inputs)
            return idx, res['embeddings']

        all_results = [None] * len(batches)
        with ThreadPoolExecutor(max_workers=n_workers) as executor:
            future_to_idx = {executor.submit(embed_batch, i): i for i in range(len(batches))}
            completed = 0
            for future in as_completed(future_to_idx):
                idx, result = future.result()
                all_results[idx] = result
                completed += len(batches[idx])
                if req_id is not None:
                    pct = int((completed / len(chunks)) * 100)
                    sys.stdout.write(json.dumps({
                        "id": req_id, "type": "progress", "pct": pct,
                        "msg": f"Embedding chunks {completed}/{len(chunks)}..."
                    }) + "\n")
                    sys.stdout.flush()

        all_embeds = []
        for r in all_results:
            all_embeds.extend(r)

        self.chunks.extend(chunks)
        data = np.array(all_embeds).astype('float32')
        faiss.normalize_L2(data)
        self.index.add(data)

    def get_file_stats(self):
        stats = {}
        for c in self.chunks:
            f = c.get('file', '')
            if f:
                stats[f] = max(stats.get(f, 0), c.get('mtime', 0))
        return stats

    def update_delta(self, new_chunks, drop_files, model="nomic-embed-text", req_id=None, batch_size=None, max_workers=None):
        global_kb = GlobalKB.get()

        drop_set = set(drop_files)
        kept_indices = [i for i, c in enumerate(self.chunks) if c.get('file', '') not in drop_set]
        kept_chunks = [self.chunks[i] for i in kept_indices]
        kept_vectors = []

        if kept_indices:
            for i in kept_indices:
                vec = self.index.reconstruct(i)
                kept_vectors.append(vec)

        new_vectors = []
        if new_chunks:
            batch_size = batch_size or self.batch_size
            batches = [new_chunks[i : i + batch_size] for i in range(0, len(new_chunks), batch_size)]
            n_workers = _effective_workers(len(batches), max_workers if max_workers and max_workers > 0 else self.max_workers_cfg)

            def embed_new_batch(idx):
                batch = batches[idx]
                prefix = "search_document: " if "nomic-embed-text" in model else ""
                inputs = [prefix + str(c['text']) for c in batch]
                client = _get_client()
                res = client.embed(model=model, input=inputs)
                return idx, res['embeddings']

            new_results = [None] * len(batches)
            with ThreadPoolExecutor(max_workers=n_workers) as executor:
                future_to_idx = {executor.submit(embed_new_batch, i): i for i in range(len(batches))}
                completed = 0
                for future in as_completed(future_to_idx):
                    idx, result = future.result()
                    new_results[idx] = result
                    completed += len(batches[idx])
                    if req_id is not None:
                        pct = int((completed / len(new_chunks)) * 100)
                        sys.stdout.write(json.dumps({
                            "id": req_id, "type": "progress", "pct": pct,
                            "msg": f"Embedding new chunks {completed}/{len(new_chunks)}..."
                        }) + "\n")
                        sys.stdout.flush()

            for r in new_results:
                new_vectors.extend(r)

            for chunk in new_chunks:
                global_kb.lookup_or_store(chunk.get('text', ''), chunk, model)

        final_vectors = kept_vectors + new_vectors
        final_chunks = kept_chunks + new_chunks

        self.index = faiss.IndexFlatIP(768)
        if final_vectors:
            data = np.array(final_vectors).astype('float32')
            faiss.normalize_L2(data)
            self.index.add(data)

        self.chunks = final_chunks
        self.save()

    def clear(self):
        self.chunks = []
        self.index = faiss.IndexFlatIP(768)

    def save(self):
        os.makedirs(os.path.dirname(self.index_path), exist_ok=True)
        tmp_index = self.index_file + ".tmp"
        tmp_meta = self.meta_file + ".tmp"

        try:
            faiss.write_index(self.index, tmp_index)
            with open(tmp_meta, 'w') as f:
                json.dump(self.chunks, f)
            os.replace(tmp_index, self.index_file)
            os.replace(tmp_meta, self.meta_file)
        except Exception as e:
            if os.path.exists(tmp_index):
                os.remove(tmp_index)
            if os.path.exists(tmp_meta):
                os.remove(tmp_meta)
            raise e

    def search(self, query, k=10, model="nomic-embed-text", file_filter=None, ignore_patterns=None):
        if self.index.ntotal == 0:
            return []

        prefix = "search_query: " if "nomic-embed-text" in model else ""
        client = _get_client()
        res = client.embed(model=model, input=[prefix + str(query)])
        q_emb = np.array(res['embeddings'], dtype='float32')
        faiss.normalize_L2(q_emb)
        search_k = min(self.index.ntotal, 10000 if (file_filter or ignore_patterns) else k * 10)
        scores, indices = self.index.search(q_emb, search_k)

        bm25_scores = None
        if self.index.ntotal > 0 and self.chunks:
            bm25 = BM25(self.chunks)
            bm25_scores = bm25.score(query)
            bm25_max = max(bm25_scores) if bm25_scores else 1.0
            if bm25_max > 0:
                bm25_scores = [s / bm25_max for s in bm25_scores]

        results = []
        seen = set()
        best_score = float(scores[0][0]) if len(scores[0]) > 0 else 0

        for i, idx in enumerate(indices[0]):
            if i >= min(search_k, 1000):
                break
            score_val = float(scores[0][i])
            if score_val < 0.3 and results:
                break
            if i > 0 and score_val < best_score - 0.25:
                break

            if 0 <= idx < len(self.chunks):
                chunk = self.chunks[idx]
                file_path = chunk.get('file', '')
                if file_filter and file_path != file_filter:
                    continue
                if ignore_patterns:
                    if any(re.search(p, file_path) for p in ignore_patterns):
                        continue
                if idx in seen:
                    continue
                seen.add(idx)

                bm25_val = bm25_scores[idx] if bm25_scores else 0.0
                sem_score = (score_val - 0.3) / 0.5 if score_val >= 0.3 else 0.0
                fused_score = 0.6 * sem_score + 0.4 * bm25_val
                ui_score = min(100.0, fused_score * 100)

                base_line = chunk.get('line', 1)
                code_text = chunk.get('code_text', '')
                offset = find_best_line(query, code_text) if code_text else 0

                results.append({
                    "score": round(ui_score, 1),
                    "file": chunk.get('file', ''),
                    "line": base_line + offset,
                    "func": chunk.get('name', ''),
                    "snippet": chunk.get('text', '')
                })

        results.sort(key=lambda x: x['score'], reverse=True)
        return results[:k]

def main():
    idx_instance = None

    while True:
        line = sys.stdin.readline()
        if not line:
            break
        try:
            req = json.loads(line.strip())
            req_id = req.get("id")
            cmd = req.get("cmd")
            args = req.get("args", {})

            res = {"id": req_id, "result": None, "error": None}

            if cmd == "init":
                idx_instance = CodeIndex(args.get("index_path"), args.get("batch_size"), args.get("max_workers"))
                res["result"] = {"status": "ok", "total": idx_instance.index.ntotal}
            elif cmd == "clear":
                if idx_instance:
                    idx_instance.clear()
                    res["result"] = "ok"
                else:
                    res["error"] = "not initialized"
            elif cmd == "add_chunks":
                if idx_instance:
                    idx_instance.add_chunks(args.get("chunks", []), args.get("model", "nomic-embed-text"), req_id=req_id)
                    res["result"] = "ok"
                else:
                    res["error"] = "not initialized"
            elif cmd == "get_file_stats":
                if idx_instance:
                    res["result"] = idx_instance.get_file_stats()
                else:
                    res["error"] = "not initialized"
            elif cmd == "update_delta":
                if idx_instance:
                    idx_instance.update_delta(
                        args.get("chunks", []), args.get("drop", []),
                        args.get("model", "nomic-embed-text"), req_id=req_id,
                        batch_size=args.get("batch_size"), max_workers=args.get("max_workers")
                    )
                    res["result"] = "ok"
                else:
                    res["error"] = "not initialized"
            elif cmd == "save":
                if idx_instance:
                    idx_instance.save()
                    res["result"] = "ok"
                else:
                    res["error"] = "not initialized"
            elif cmd == "stop":
                sys.exit(0)
            elif cmd == "status":
                if idx_instance:
                    res["result"] = {
                        "total_chunks": len(idx_instance.chunks),
                        "index_ntotal": idx_instance.index.ntotal,
                        "healthy": len(idx_instance.chunks) == idx_instance.index.ntotal
                    }
                else:
                    res["error"] = "not initialized"
            elif cmd == "cross_search":
                model = args.get("model", "nomic-embed-text")
                k = args.get("k", 10)
                query = args.get("query", "")
                prefix = "search_query: " if "nomic-embed-text" in model else ""
                try:
                    client = _get_client()
                    res = client.embed(model=model, input=[prefix + str(query)])
                    q_emb = np.array(res['embeddings'], dtype='float32')
                    faiss.normalize_L2(q_emb)
                    gkb = GlobalKB.get()
                    if gkb.ntotal() == 0:
                        res["result"] = []
                    else:
                        scores, indices = gkb.index.search(q_emb, min(gkb.ntotal(), 100))
                        hits = []
                        for idx in indices[0]:
                            if idx < 0 or len(hits) >= k:
                                break
                            chunk = gkb.chunks[idx] if idx < len(gkb.chunks) else None
                            if not chunk:
                                continue
                            score_val = float(scores[0][len(hits)])
                            ui_score = min(100.0, ((score_val - 0.3) / 0.5) * 100 if score_val >= 0.3 else 0.0)
                            hits.append({
                                "score": round(ui_score, 1),
                                "file": chunk.get('file', ''),
                                "line": chunk.get('line', 1),
                                "func": chunk.get('name', ''),
                                "snippet": chunk.get('text', ''),
                                "source": "global"
                            })
                        res["result"] = hits
                except Exception as e:
                    res["error"] = str(e)
            elif cmd == "search":
                if idx_instance:
                    hits = idx_instance.search(
                        args.get("query"), args.get("k", 10), args.get("model", "nomic-embed-text"),
                        args.get("file_filter"), args.get("ignore_patterns")
                    )
                    res["result"] = hits
                else:
                    res["error"] = "not initialized"
            elif cmd == "warmup":
                model = args.get("model", "nomic-embed-text")
                try:
                    client = _get_client()
                    client.embed(model=model, input=["warmup"])
                    res["result"] = {"status": "ok"}
                except Exception as e:
                    res["error"] = str(e)
            elif cmd == "global_stats":
                gkb = GlobalKB.get()
                res["result"] = {
                    "chunks": gkb.ntotal(),
                    "metadata_entries": len(gkb.chunks)
                }
            else:
                res["error"] = "unknown command"

            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()
        except Exception as e:
            sys.stdout.write(json.dumps({"error": str(e), "id": locals().get("req_id", -1)}) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()