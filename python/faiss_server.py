import faiss
import numpy as np
import ollama
import json
import sys

class CodeIndex:
    def __init__(self): 
        # nomic-embed-text typically uses 768 dims
        self.index = faiss.IndexFlatIP(768)
        self.chunks = []
        
    def add_chunks(self, chunks): 
        embeds = []
        for c in chunks:
            emb = ollama.embeddings(model='nomic-embed-text', prompt=c['text'])['embedding']
            embeds.append(emb)
            self.chunks.append(c) # keep metadata
        
        if embeds:
            self.index.add(np.array(embeds).astype('f32'))
            
    def search(self, query, k=5):
        try:
            q_emb = ollama.embeddings(model='nomic-embed-text', prompt=query)['embedding']
            scores, indices = self.index.search(np.array([q_emb]).astype('f32'), k)
            
            # format results with metadata
            results = []
            for i, idx in enumerate(indices[0]):
                if idx < len(self.chunks) and idx >= 0:
                    chunk = self.chunks[idx]
                    results.append({
                        "score": round(float(scores[0][i]) * 100, 2), # % confidence equivalent
                        "file": chunk.get('file', ''),
                        "line": chunk.get('line', 1),
                        "func": chunk.get('name', ''),
                        "snippet": chunk.get('text', '')
                    })
            return results
        except Exception as e:
            return [{"error": str(e)}]

if __name__ == "__main__":
    # simple CLI mode for neovim communication (e.g., echo "search foo" | python faiss_server.py)
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "search":
        idx = CodeIndex()
        # mock / load real index - to be integrated with disk storage later
        query = sys.argv[2]
        print(json.dumps(idx.search(query)))
