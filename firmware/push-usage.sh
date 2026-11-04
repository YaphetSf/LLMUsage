#!/usr/bin/env bash
set -euo pipefail

exec /usr/bin/curl --noproxy '*' --silent --show-error --fail --max-time 8 \
  -X POST \
  -H 'Content-Type: application/json' \
  -H "X-Now: $(date +%s)" \
  --data-binary @"$HOME/Library/Application Support/LLMUsage/usage.json" \
  http://llmusage-display.local/usage
