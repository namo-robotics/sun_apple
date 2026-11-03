#!/usr/bin/env bash
# Build the Apple bindings and exercise native calls without requesting screen access.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
if [[ "$(uname -s)" != Darwin || "$(uname -m)" != arm64 ]]; then
  echo 'sun_apple currently supports Apple Silicon macOS.' >&2
  exit 1
fi
compiler="${SUN_COMPILER:-sun}"
build_root=$("$compiler" describe --config sun-config.json | python3 -c 'import json,sys; print(json.load(sys.stdin)["build_root"])')
"$compiler" build --config sun-config.json --no-test
# The system loader registers Objective-C classes for JIT clients.
xcrun clang -dynamiclib "$build_root/native/capture.o" "$build_root/native/movie.o" -mmacosx-version-min=15.2 \
  -install_name @rpath/libsun_apple_native.dylib \
  -framework AppKit -framework ScreenCaptureKit -framework AVFoundation \
  -framework CoreMedia -framework CoreGraphics -framework CoreVideo -framework CoreImage -framework ImageIO \
  -o "$build_root/native/libsun_apple_native.dylib"
"$compiler" fmt --check src tests
"$compiler" --lib-path "$build_root" \
  -lobjc "-L$build_root/native" -lsun_apple_native \
  -l/System/Library/Frameworks/AppKit.framework/AppKit \
  -l/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit \
  -l/System/Library/Frameworks/AVFoundation.framework/AVFoundation \
  -l/System/Library/Frameworks/CoreMedia.framework/CoreMedia \
  -l/System/Library/Frameworks/Foundation.framework/Foundation \
  -l/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation \
  -l/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics \
  -l/System/Library/Frameworks/CoreVideo.framework/CoreVideo \
  -l/System/Library/Frameworks/CoreImage.framework/CoreImage \
  -l/System/Library/Frameworks/ImageIO.framework/ImageIO \
  tests/main.sun
"$compiler" --lib-path "$build_root" --emit-obj -o "$build_root/bindings-smoke.o" tests/main.sun
xcrun clang++ "$build_root/bindings-smoke.o" "$build_root/native/libsun_apple_native.a" -lobjc -framework AppKit -framework ScreenCaptureKit -framework AVFoundation -framework CoreMedia \
  -framework Foundation -framework CoreFoundation \
  -framework CoreGraphics -framework CoreVideo -framework CoreImage -framework ImageIO -o "$build_root/bindings-smoke"
"$build_root/bindings-smoke"
xcrun clang -fobjc-arc -Wall -Wextra -Werror -Wno-unused-parameter -mmacosx-version-min=15.2 tests/movie.m "$build_root/native/movie.o" \
  -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreVideo -framework CoreImage -framework CoreGraphics -o "$build_root/movie-tests"
"$build_root/movie-tests"
"$build_root/movie-tests" --interrupt
