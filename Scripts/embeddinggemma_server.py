#!/usr/bin/env python3
"""Local EmbeddingGemma 2 Inference Server for MyComputerAgent.

Provides zero-decoding System One decision evaluation (/v1/evaluate) and
Matryoshka representation embeddings (/v1/embed) using Google DeepMind's
EmbeddingGemma 2 (270M text backbone).

Inspired by and compatible with clef-doom (clef_doom/embedding.py) and
personal-knowledge/EmbeddingGemma2/decision_maker_local.py.

Key Specs:
- Model: google/embeddinggemma-2
- Precision: float32 on Apple Silicon (MPS) / CPU (float16 yields NaN)
- Modular loading: vision and audio encoders disabled (text-only 270M)
- MRL: 256d with L2 re-normalization
- Latency: ~25ms per decision on Apple Silicon MPS
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import sys
import time
from functools import lru_cache
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Dict, List, Optional, Tuple

import torch
import torch.nn.functional as F

try:
    from sentence_transformers import SentenceTransformer
except ImportError:
    SentenceTransformer = None

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger("embeddinggemma-server")

MODEL_ID = "google/embeddinggemma-2"
PROMPT_CLASSIFICATION = "task: classification | query: "
PROMPT_SEARCH = "task: search result | query: "
DEFAULT_TEMPERATURE = 0.05
DEFAULT_MRL_DIM = 256


class EmbeddingGemmaEngine:
    def __init__(self, device: Optional[str] = None):
        if SentenceTransformer is None:
            raise RuntimeError(
                "sentence-transformers is not installed. Please install torch and sentence-transformers."
            )

        if device is None:
            self.device = "mps" if torch.backends.mps.is_available() else "cpu"
        else:
            self.device = device

        logger.info(f"Loading {MODEL_ID} on {self.device} with torch.float32 (text-only 270M)...")
        t0 = time.perf_counter()
        # Disabling vision_config and audio_config keeps only the 270M text backbone
        self.model = SentenceTransformer(
            MODEL_ID,
            device=self.device,
            model_kwargs={"torch_dtype": torch.float32},
            config_kwargs={"vision_config": None, "audio_config": None},
        )
        t1 = time.perf_counter()
        logger.info(f"Model loaded in {t1 - t0:.2f}s on {self.device}")

        # Cache for criteria embeddings to enable sub-20ms evaluation
        self._cache: Dict[str, torch.Tensor] = {}

    def encode(
        self,
        texts: List[str],
        prefix: str = PROMPT_CLASSIFICATION,
        dim: Optional[int] = None,
    ) -> torch.Tensor:
        """Encodes texts into normalized float tensors, optionally sliced by MRL."""
        prefixed = [prefix + t for t in texts]
        with torch.no_grad():
            embs = self.model.encode(
                prefixed,
                convert_to_tensor=True,
                normalize_embeddings=True,
                device=self.device,
            ).float()

            if embs.dim() == 1:
                embs = embs.unsqueeze(0)

            # Matryoshka Representation Learning (MRL) dimension reduction
            if dim is not None and dim < embs.shape[-1]:
                embs = embs[:, :dim]
                # CRITICAL: Re-normalize L2 after slicing MRL dimensions!
                embs = F.normalize(embs, p=2, dim=-1)

            return embs

    def _get_criteria_embeddings(self, criteria: Dict[str, str]) -> Tuple[List[str], torch.Tensor]:
        """Caches option embeddings so repeated evaluation costs only one state encode."""
        keys = list(criteria.keys())
        descriptions = [criteria[k] for k in keys]
        
        # Cache key based on criteria content hash
        cache_key = hashlib.sha256(";;;".join(f"{k}:{v}" for k, v in zip(keys, descriptions)).encode("utf-8")).hexdigest()
        if cache_key in self._cache:
            return keys, self._cache[cache_key]

        embs = self.encode(descriptions, prefix=PROMPT_CLASSIFICATION)
        # Limit cache size
        if len(self._cache) > 200:
            self._cache.clear()
        self._cache[cache_key] = embs
        return keys, embs

    def evaluate_request(self, request_data: Dict[str, Any]) -> Dict[str, Any]:
        """Evaluates System One questions against application state."""
        state = request_data.get("state", {})
        questions = request_data.get("questions", {})
        
        user_goal = ""
        active_app = ""
        candidates_summary = ""

        if isinstance(state, dict):
            user_goal = str(state.get("user_goal", "")).strip()
            active_app = str(state.get("active_app", "")).strip()
            candidates = state.get("candidates", [])
            if isinstance(candidates, list) and candidates:
                cand_texts = []
                for c in candidates[:10]:
                    if isinstance(c, dict):
                        role = c.get("role", "")
                        label = c.get("label", "") or c.get("value", "")
                        cand_texts.append(f"{role} '{label}'")
                candidates_summary = " Visible elements: " + ", ".join(cand_texts)

        # Build context description
        context_text = f"User goal: {user_goal}. Active application: {active_app}.{candidates_summary}"
        context_emb = self.encode([context_text], prefix=PROMPT_CLASSIFICATION)

        answers: Dict[str, Any] = {}

        for q_id, q_payload in questions.items():
            q_type = q_payload.get("type", "choice")
            instructions = q_payload.get("instructions", "")
            criteria = q_payload.get("criteria", {})

            if q_type == "choice" and criteria:
                keys, opt_embs = self._get_criteria_embeddings(criteria)
                # Cosine similarity + softmax
                sims = (context_emb @ opt_embs.T).squeeze(0) / DEFAULT_TEMPERATURE
                probs = F.softmax(sims, dim=0).cpu().tolist()

                prob_dict = {k: round(p, 4) for k, p in zip(keys, probs)}
                winning_key = max(prob_dict, key=prob_dict.get)

                answers[q_id] = {
                    "type": "choice",
                    "choice": winning_key,
                    "confidence": prob_dict[winning_key],
                    "probabilities": prob_dict,
                }

            elif q_type == "noul" or "accomplished" in instructions.lower():
                # Predicate / Completion test (Yes / No)
                affirmative = f"The goal '{user_goal}' is already fully accomplished and satisfied on screen."
                negative = f"The goal '{user_goal}' is NOT accomplished yet. Further interaction is required."
                
                cond_embs = self.encode([affirmative, negative], prefix=PROMPT_CLASSIFICATION)
                sims = (context_emb @ cond_embs.T).squeeze(0) / DEFAULT_TEMPERATURE
                probs = F.softmax(sims, dim=0).cpu().tolist()
                p_yes = round(probs[0], 4)

                answers[q_id] = {
                    "type": "noul",
                    "noul": p_yes,
                    "confidence": max(p_yes, round(1.0 - p_yes, 4)),
                }

            elif q_type == "score" and criteria:
                # Rubric expected score
                try:
                    num_keys = sorted([int(k) for k in criteria.keys()])
                    descriptions = [criteria[str(k)] for k in num_keys]
                    r_embs = self.encode(descriptions, prefix=PROMPT_CLASSIFICATION)
                    sims = (context_emb @ r_embs.T).squeeze(0) / DEFAULT_TEMPERATURE
                    probs = F.softmax(sims, dim=0).cpu().tolist()
                    expected = sum(k * p for k, p in zip(num_keys, probs))
                    answers[q_id] = {
                        "type": "score",
                        "score": round(expected, 2),
                    }
                except Exception:
                    answers[q_id] = {"type": "score", "score": 0.0}

            else:
                answers[q_id] = {"type": q_type, "choice": "none", "confidence": 0.0}

        return {
            "model": MODEL_ID,
            "answers": answers,
            "usage": {
                "input_tokens": len(context_text.split()),
                "output_tokens": len(answers),
            },
        }

    def embed_text(self, text: str, dim: int = DEFAULT_MRL_DIM) -> List[float]:
        """Embeds single text string with MRL truncation and L2 re-normalization."""
        t_emb = self.encode([text], prefix=PROMPT_SEARCH, dim=dim)
        return t_emb[0].cpu().tolist()


# Global engine instance
_engine: Optional[EmbeddingGemmaEngine] = None


def get_engine(device: Optional[str] = None) -> EmbeddingGemmaEngine:
    global _engine
    if _engine is None:
        _engine = EmbeddingGemmaEngine(device=device)
    return _engine


class RequestHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args: Any) -> None:
        # Suppress noisy standard request logging unless error
        if args and str(args[1]).startswith("4"):
            logger.warning("%s - " + format, self.address_string(), *args)

    def _send_json(self, status: int, data: Any) -> None:
        body = json.dumps(data).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:
        if self.path == "/health" or self.path == "/":
            engine = get_engine()
            self._send_json(200, {
                "status": "ok",
                "model": MODEL_ID,
                "device": engine.device,
                "dtype": "float32",
                "default_dim": DEFAULT_MRL_DIM,
            })
        else:
            self._send_json(404, {"error": "Not Found"})

    def do_POST(self) -> None:
        content_length = int(self.headers.get("Content-Length", 0))
        if content_length == 0:
            self._send_json(400, {"error": "Empty body"})
            return

        body_bytes = self.rfile.read(content_length)
        try:
            req_json = json.loads(body_bytes.decode("utf-8"))
        except Exception as e:
            self._send_json(400, {"error": f"Invalid JSON: {e}"})
            return

        engine = get_engine()

        if self.path in ("/v1/evaluate", "/evaluate"):
            # System One Decision Evaluation
            t0 = time.perf_counter()
            resp = engine.evaluate_request(req_json)
            latency_ms = (time.perf_counter() - t0) * 1000
            resp["latency_ms"] = round(latency_ms, 2)
            self._send_json(200, resp)

        elif self.path in ("/v1/embed", "/embed"):
            # Text Embedding Generation
            dim = int(req_json.get("dim", DEFAULT_MRL_DIM))
            if "text" in req_json:
                vector = engine.embed_text(req_json["text"], dim=dim)
                self._send_json(200, {"dim": dim, "vector": vector})
            elif "texts" in req_json:
                texts = req_json["texts"]
                embs = engine.encode(texts, prefix=PROMPT_SEARCH, dim=dim)
                self._send_json(200, {"dim": dim, "vectors": embs.cpu().tolist()})
            else:
                self._send_json(400, {"error": "Missing 'text' or 'texts' field"})

        else:
            self._send_json(404, {"error": f"Path not found: {self.path}"})


def main() -> None:
    parser = argparse.ArgumentParser(description="EmbeddingGemma 2 Inference Server")
    parser.add_argument("--host", default="127.0.0.1", help="Host interface (default: 127.0.0.1)")
    parser.add_argument("--port", type=int, default=38765, help="Port (default: 38765)")
    parser.add_argument("--device", default=None, help="Device (mps, cpu, cuda)")
    args = parser.parse_args()

    # Pre-warm model on startup
    get_engine(device=args.device)

    server = ThreadingHTTPServer((args.host, args.port), RequestHandler)
    logger.info(f"EmbeddingGemma 2 Server running at http://{args.host}:{args.port}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        logger.info("Stopping server...")
        server.server_close()


if __name__ == "__main__":
    main()
