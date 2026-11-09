#!/usr/bin/env bash
set -euo pipefail
export FASTRA_RELEASE_MODE=1
exec "$(dirname -- "${BASH_SOURCE[0]}")/package.sh" "$@"
