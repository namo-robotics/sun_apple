#!/usr/bin/env bash
# Build and stage a release archive for clients that consume published bindings.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
./build.sh
prefix=build/package
mkdir -p "$prefix/lib/sun" "$prefix/lib" "$prefix/share/sun_apple"
install -m 644 build/sun_apple.moon "$prefix/lib/sun/"
install -m 644 build/native/libsun_apple_native.a "$prefix/lib/"
install -m 755 build/native/libsun_apple_native.dylib "$prefix/lib/"
install -m 644 LICENSE "$prefix/share/sun_apple/"
"${SUN_COMPILER:-sun}" --version > "$prefix/share/sun_apple/sun-version.txt"
tar -C "$prefix" -czf build/sun_apple-arm64-apple-darwin.tar.gz .
shasum -a 256 build/sun_apple-arm64-apple-darwin.tar.gz > build/sun_apple-arm64-apple-darwin.tar.gz.sha256
