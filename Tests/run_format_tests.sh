#!/bin/bash
# run_format_tests.sh — Run the Voice formatting rule test suite.
#
# Usage:
#   ./run_format_tests.sh                         # defaults (localhost:11434, qwen3:1.7b)
#   ./run_format_tests.sh --model qwen3:0.6b      # use smaller model
#   ./run_format_tests.sh --url http://host:11434  # remote Ollama
#   ./run_format_tests.sh -v                       # verbose (inline diffs)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEST_SCRIPT="$SCRIPT_DIR/format_test.py"

# Check Python 3 is available
if ! command -v python3 &>/dev/null; then
    echo "Error: python3 not found. Install Python 3.9+."
    exit 1
fi

# Check the test script exists
if [ ! -f "$TEST_SCRIPT" ]; then
    echo "Error: format_test.py not found at $TEST_SCRIPT"
    exit 1
fi

# Pass all arguments through
exec python3 "$TEST_SCRIPT" "$@"
