#!/bin/bash
# Install the read-only intelligence worker independently of the trading app.
set -euo pipefail
cd "$(dirname "$0")/.."
runtime="${1:-$HOME/Library/Application Support/MayStock/IntelligenceRuntime}"
python_bin="${MAYSTOCK_BOOTSTRAP_PYTHON:-$(command -v python3)}"
"$python_bin" -m venv "$runtime"
"$runtime/bin/python3" -m pip install --disable-pip-version-check -r Intelligence/requirements.txt
"$runtime/bin/python3" -c 'from claude_agent_sdk import ClaudeAgentOptions, query; print("Claude Agent SDK ready")'
echo "Intelligence runtime: $runtime"
