#!/usr/bin/env bash
# Test the built bindings through standalone linkage and synthetic media.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
compiler=${SUN_COMPILER:-sun}
build_root=$("$compiler" describe --config sun-config.json --field build_root)

# Compile against the moon's embedded archive, as a downstream application does.
"$compiler" build --config sun-config.json --entrypoint bindings_smoke --no-test
"$build_root/bindings_smoke"

# Synthetic inputs exercise encoding and recovery without capturing the screen.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -mmacosx-version-min=15.2 tests/movie.m "$build_root/native/movie.o" \
  -framework Foundation -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreImage -framework CoreGraphics \
  -o "$build_root/movie-tests"
"$build_root/movie-tests"
"$build_root/movie-tests" --interrupt
