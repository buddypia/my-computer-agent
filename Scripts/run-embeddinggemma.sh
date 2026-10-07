#!/usr/bin/env bash
set -euo pipefail

# Helper launcher for EmbeddingGemma 2 Local Server
# Detects available Python environments with torch + sentence_transformers

PORT="${1:-8765}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_PY="${SCRIPT_DIR}/embeddinggemma_server.py"

PYTHON_BIN=""

if [[ -n "${MCA_PYTHON:-}" && -x "${MCA_PYTHON}" ]]; then
    PYTHON_BIN="${MCA_PYTHON}"
elif [[ -x "${SCRIPT_DIR}/../.venv/bin/python" ]]; then
    PYTHON_BIN="${SCRIPT_DIR}/../.venv/bin/python"
elif [[ -x "${SCRIPT_DIR}/../../../../oss/clef-doom/.venv/bin/python" ]]; then
    PYTHON_BIN="${SCRIPT_DIR}/../../../../oss/clef-doom/.venv/bin/python"
elif [[ -x "${HOME}/dev/oss/clef-doom/.venv/bin/python" ]]; then
    PYTHON_BIN="${HOME}/dev/oss/clef-doom/.venv/bin/python"
elif command -v uv >/dev/null 2>&1; then
    exec uv run --with torch --with sentence-transformers python3 "${SERVER_PY}" --port "${PORT}"
elif command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="python3"
fi

if [[ -z "${PYTHON_BIN}" ]]; then
    echo "❌ Error: Python with torch & sentence-transformers not found." >&2
    echo "Please set MCA_PYTHON=/path/to/python or install uv." >&2
    exit 1
fi

echo "🚀 Starting EmbeddingGemma 2 server with ${PYTHON_BIN} on port ${PORT}..."
exec "${PYTHON_BIN}" "${SERVER_PY}" --port "${PORT}"
