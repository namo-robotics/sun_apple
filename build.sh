#!/usr/bin/env bash
# Build and package the bindings, then run checks without requesting screen access.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]]; then
  echo 'sun_apple currently supports Apple Silicon macOS.' >&2
  exit 1
fi

compiler=${SUN_COMPILER:-sun}
"$compiler" build --config sun-config.json --no-test
"$compiler" fmt --check src tests
./scripts/test-macos.sh
