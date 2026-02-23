#!/usr/bin/env bash
set -euo pipefail
exec python3 "$(dirname "$0")/load-baseline.py" "$@"
