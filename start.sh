#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"
if [[ ! -f .env ]]; then
  echo "Missing .env — copy .env.example and fill in values." >&2
  exit 1
fi
set -a
source .env
set +a
exec claude --dangerously-skip-permissions "$@"
