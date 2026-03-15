import sys
import json
import os
import faiss
import numpy as np
import ollama

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

    def add_chunks(self, chunks, model="nomic-embed-text"):
        embeds = []
        for c in chunks:
            try:
                emb = ollama.embeddings(model=model, prompt=c['text'])['embedding']
                embeds.append(emb)
                self.chunks.append(c)
            except Exception as e:
                raise Exception(f"Failed embedding chunk (is model '{model}' pulled?): {str(e)}")
        
        if embeds:
            self.index.add(np.array(embeds).astype('float32'))
            
    def save(self):
        os.makedirs(os.path.dirname(self.index_path), exist_ok=True)
        faiss.write_index(self.index, self.index_file)
        with open(self.meta_file, 'w') as f:
            json.dump(self.chunks, f)

    def search(self, query, k=10, model="nomic-embed-text", file_filter=None):
        if self.index.ntotal == 0:
            return []
        try:
            q_emb = ollama.embeddings(model=model, prompt=query)['embedding']
            search_k = min(self.index.ntotal, 10000 if file_filter else k)
            scores, indices = self.index.search(np.array([q_emb]).astype('float32'), search_k)
            
            results = []
            for i, idx in enumerate(indices[0]):
                if len(results) >= k:
                    break
                if 0 <= idx < len(self.chunks) and idx >= 0:
                    chunk = self.chunks[idx]
                    if file_filter and chunk.get('file', '') != file_filter:
                        continue
                    score_val = float(scores[0][i]) * 100
                    results.append({
                        "score": round(score_val, 2),
                        "file": chunk.get('file', ''),
                        "line": chunk.get('line', 1),
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
            elif cmd == "add_chunks":
                if idx_instance:
                    idx_instance.add_chunks(args.get("chunks", []), args.get("model", "nomic-embed-text"))
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
