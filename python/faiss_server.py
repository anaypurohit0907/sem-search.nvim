import re
import sys
import json
import os
import faiss
import numpy as np
import ollama


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
            self.index = faiss.read_index(self.index_file)
            if os.path.exists(self.meta_file):
                with open(self.meta_file, 'r') as f:
                    self.chunks = json.load(f)
        else:
            self.index = faiss.IndexFlatIP(768)

    def add_chunks(self, chunks, model="nomic-embed-text", req_id=None):
        if not chunks:
            return

        batch_size = 25
        for i in range(0, len(chunks), batch_size):
            batch = chunks[i : i + batch_size]
            try:
                if req_id is not None:
                    pct = int(((i + len(batch)) / len(chunks)) * 100)
                    sys.stdout.write(json.dumps({
                        "id": req_id,
                        "type": "progress",
                        "msg": f"Embedding chunks {i+1}-{i+len(batch)} of {len(chunks)}...",
                        "pct": pct
                    }) + "\n")
                    sys.stdout.flush()

                # Nomic-embed-text requires the correct prompt prefix for retrieval tasks
                prefix = "search_document: " if "nomic-embed-text" in model else ""

                # Batch process embeddings
                inputs = [prefix + str(c['text']) for c in batch]
                res = ollama.embed(model=model, input=inputs)

                # Add embeddings and chunks to index
                batch_embeds = res['embeddings']
                for j, emb in enumerate(batch_embeds):
                    self.chunks.append(batch[j])
                    # We'll collect all embeddings and add to FAISS at once for efficiency after the loop
                    # but for now, let's keep it simple and add them to a local list

                if i == 0:
                    self.all_embeds = list(batch_embeds)
                else:
                    self.all_embeds.extend(batch_embeds)

            except Exception as e:
                raise Exception(f"Failed embedding batch starting at {i}: {str(e)}")

        if hasattr(self, 'all_embeds') and self.all_embeds:
            data = np.array(self.all_embeds).astype('float32')
            faiss.normalize_L2(data)
            self.index.add(data)
            del self.all_embeds            
    def clear(self):
        self.chunks = []
        self.index = faiss.IndexFlatIP(768)

    def save(self):
        os.makedirs(os.path.dirname(self.index_path), exist_ok=True)
        faiss.write_index(self.index, self.index_file)
        with open(self.meta_file, 'w') as f:
            json.dump(self.chunks, f)

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
            elif cmd == "save":
                if idx_instance:
                    idx_instance.save()
                    res["result"] = "ok"
                else:
                    res["error"] = "not initialized"
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
