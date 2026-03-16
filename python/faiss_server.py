import re
import sys
import json
import os
import faiss
import numpy as np
import ollama
from concurrent.futures import ThreadPoolExecutor, as_completed


def find_best_line(query, code_text):
    if not code_text: return 0
    query_terms = [t.lower() for t in re.findall(r'[a-zA-Z0-9_]+', query)]
    if not query_terms: return 0
    
    stop_words = {'and', 'the', 'for', 'that', 'this', 'with', 'from', 'have', 'has', 'function', 'local', 'return', 'end', 'then', 'else', 'elseif'}
    filtered_terms = [t for t in query_terms if list(t) and len(t) > 2 and t not in stop_words]
    if not filtered_terms:
        filtered_terms = query_terms # fallback if all are stop words
        
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
    if best_score <= 0:
        return 0
    return best_idx

class CodeIndex:
    def __init__(self, index_path):
        self.index_path = index_path
        self.index_file = index_path + ".index"
        self.meta_file = index_path + ".meta.json"
        
        self.chunks = []
        if os.path.exists(self.index_file):
            try:
                self.index = faiss.read_index(self.index_file)
                if os.path.exists(self.meta_file):
                    with open(self.meta_file, 'r') as f:
                        self.chunks = json.load(f)
            except Exception as e:
                # Log error and start fresh if corrupt
                sys.stderr.write(f"Warning: Failed to load index, starting fresh: {str(e)}\n")
                self.index = faiss.IndexFlatIP(768)
                self.chunks = []
        else:
            self.index = faiss.IndexFlatIP(768)

    def add_chunks(self, chunks, model="nomic-embed-text", req_id=None):
        if not chunks:
            return

        batch_size = 50
        batches = [chunks[i : i + batch_size] for i in range(0, len(chunks), batch_size)]

        def embed_batch(idx):
            batch = batches[idx]
            prefix = "search_document: " if "nomic-embed-text" in model else ""
            inputs = [prefix + str(c['text']) for c in batch]
            try:
                res = ollama.embed(model=model, input=inputs)
                return idx, res['embeddings']
            except Exception as e:
                return idx, e

        all_results = [None] * len(batches)
        # Using 2 workers is safer for local Ollama instances to avoid hanging
        with ThreadPoolExecutor(max_workers=2) as executor:
            future_to_idx = {executor.submit(embed_batch, i): i for i in range(len(batches))}
            completed = 0
            for future in as_completed(future_to_idx):
                idx, result = future.result()
                if isinstance(result, Exception):
                    raise result
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
                # Store the max mtime seen for this file (should be consistent across chunks)
                stats[f] = max(stats.get(f, 0), c.get('mtime', 0))
        return stats

    def update_delta(self, new_chunks, drop_files, model="nomic-embed-text", req_id=None):
        drop_set = set(drop_files)
        kept_indices = [i for i, c in enumerate(self.chunks) if c.get('file', '') not in drop_set]

        kept_chunks = [self.chunks[i] for i in kept_indices]
        kept_vectors = []

        if len(kept_indices) > 0:
            for i in kept_indices:
                vec = self.index.reconstruct(i)
                kept_vectors.append(vec)

        new_vectors = []
        if new_chunks:
            batch_size = 50
            batches = [new_chunks[i : i + batch_size] for i in range(0, len(new_chunks), batch_size)]

            def embed_new_batch(idx):
                batch = batches[idx]
                prefix = "search_document: " if "nomic-embed-text" in model else ""
                inputs = [prefix + str(c['text']) for c in batch]
                try:
                    res = ollama.embed(model=model, input=inputs)
                    return idx, res['embeddings']
                except Exception as e:
                    return idx, e

            new_results = [None] * len(batches)
            with ThreadPoolExecutor(max_workers=2) as executor:
                future_to_idx = {executor.submit(embed_new_batch, i): i for i in range(len(batches))}
                completed = 0
                for future in as_completed(future_to_idx):
                    idx, result = future.result()
                    if isinstance(result, Exception):
                        raise result
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

        # Combine everything
        final_vectors = kept_vectors + new_vectors
        final_chunks = kept_chunks + new_chunks

        # Rebuild Index
        self.index = faiss.IndexFlatIP(768)
        if final_vectors:
            data = np.array(final_vectors).astype('float32')
            faiss.normalize_L2(data)
            self.index.add(data)

        self.chunks = final_chunks
        self.save()    def clear(self):
        self.chunks = []
        self.index = faiss.IndexFlatIP(768)

    def save(self):
        os.makedirs(os.path.dirname(self.index_path), exist_ok=True)
        
        # Atomic save: write to .tmp then rename
        tmp_index = self.index_file + ".tmp"
        tmp_meta = self.meta_file + ".tmp"
        
        try:
            faiss.write_index(self.index, tmp_index)
            with open(tmp_meta, 'w') as f:
                json.dump(self.chunks, f)
            
            # Atomic rename (on Linux/Unix this is atomic)
            os.replace(tmp_index, self.index_file)
            os.replace(tmp_meta, self.meta_file)
        except Exception as e:
            # Cleanup tmp files on failure
            if os.path.exists(tmp_index): os.remove(tmp_index)
            if os.path.exists(tmp_meta): os.remove(tmp_meta)
            raise e

    def search(self, query, k=10, model="nomic-embed-text", file_filter=None):
        if self.index.ntotal == 0:
            return []
        try:
            prefix = "search_query: " if "nomic-embed-text" in model else ""
            res = ollama.embed(model=model, input=prefix + str(query))
            q_emb = np.array([res['embeddings'][0]]).astype('float32')
            faiss.normalize_L2(q_emb)
            search_k = min(self.index.ntotal, 10000 if file_filter else k)
            scores, indices = self.index.search(q_emb, search_k)
            
            results = []
            best_score = float(scores[0][0])
            for i, idx in enumerate(indices[0]):
                if len(results) >= k:
                    break
                
                score_val = float(scores[0][i])
                
                # In normalized cosine similarity, reject items that are severely less relevant than the best
                # or if they fall below a baseline floor (e.g. < 0.3 meaning totally unrelated)
                if score_val < 0.3 and len(results) > 0:
                    break
                # Only keep results within a reasonable margin of the absolute best match (widened for larger line chunks)
                if i > 0 and score_val < best_score - 0.25:
                    break
                    
                if 0 <= idx < len(self.chunks) and idx >= 0:
                    chunk = self.chunks[idx]
                    if file_filter and chunk.get('file', '') != file_filter:
                        continue
                    
                    # Normalize the nomic score (0.4 to 0.8) slightly upwards for nicer UI percentages
                    # A raw 0.74 cosine similarity is actually an extremely good match for Nomic.
                    ui_score = min(100.0, max(0.0, ((score_val - 0.3) / 0.5) * 100))
                    
                    base_line = chunk.get('line', 1)
                    code_text = chunk.get('code_text', '')
                    if code_text:
                        offset = find_best_line(query, code_text)
                    else:
                        # Fallback using 'text'
                        full_text = chunk.get('text', '')
                        full_offset = find_best_line(query, full_text)
                        # subtract header lines if needed
                        header_lines = 0
                        for tline in full_text.split('\n')[:3]:
                            if tline.startswith('File: ') or tline.startswith('Context: '):
                                header_lines += 1
                            else:
                                break
                        offset = max(0, full_offset - header_lines)
                        
                    results.append({
                        "score": round(ui_score, 1),
                        "file": chunk.get('file', ''),
                        "line": base_line + offset,
                        "func": chunk.get('name', ''),
                        "snippet": chunk.get('text', '')
                    })
            return results
        except Exception as e:
            raise Exception(f"Search embedding failed (is model '{model}' pulled?): {str(e)}")

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
                idx_instance = CodeIndex(args.get("index_path"))
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
                    idx_instance.update_delta(args.get("chunks", []), args.get("drop", []), args.get("model", "nomic-embed-text"), req_id=req_id)
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
            elif cmd == "search":
                if idx_instance:
                    hits = idx_instance.search(args.get("query"), args.get("k", 10), args.get("model", "nomic-embed-text"), args.get("file_filter"))
                    res["result"] = hits
                else:
                    res["error"] = "not initialized"
            else:
                res["error"] = "unknown command"
                
            sys.stdout.write(json.dumps(res) + "\n")
            sys.stdout.flush()
        except Exception as e:
            # Avoid crashing the loop on bad request/JSON formatting
            sys.stdout.write(json.dumps({"error": str(e), "id": locals().get("req_id", -1)}) + "\n")
            sys.stdout.flush()

if __name__ == "__main__":
    main()
