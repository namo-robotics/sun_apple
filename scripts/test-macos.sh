#!/usr/bin/env bash
# Test the built bindings through JIT, standalone linkage, and synthetic media.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
compiler=${SUN_COMPILER:-sun}
build_root=$("$compiler" describe --config sun-config.json --field build_root)

# Both execution modes exercise the same Apple framework dependencies.
frameworks=(AppKit ScreenCaptureKit AVFoundation CoreMedia Foundation
  CoreFoundation CoreGraphics CoreVideo CoreImage ImageIO)
jit_flags=(-lobjc "-L$build_root/native" -lsun_apple_native)
link_flags=(-lobjc)
for framework in "${frameworks[@]}"; do
  jit_flags+=("-l/System/Library/Frameworks/$framework.framework/$framework")
  link_flags+=(-framework "$framework")
done

"$compiler" --lib-path "$build_root" "${jit_flags[@]}" tests/main.sun
"$compiler" --lib-path "$build_root" --emit-obj -o "$build_root/bindings-smoke.o" tests/main.sun
xcrun clang++ "$build_root/bindings-smoke.o" "$build_root/native/libsun_apple_native.a" \
  "${link_flags[@]}" -o "$build_root/bindings-smoke"
"$build_root/bindings-smoke"

# Synthetic inputs exercise encoding and recovery without capturing the screen.
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter \
  -mmacosx-version-min=15.2 tests/movie.m "$build_root/native/movie.o" \
  -framework Foundation -framework AVFoundation -framework CoreMedia \
  -framework CoreVideo -framework CoreImage -framework CoreGraphics \
  -o "$build_root/movie-tests"
"$build_root/movie-tests"
"$build_root/movie-tests" --interrupt
