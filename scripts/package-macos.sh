#!/usr/bin/env bash
# Collect tested Sun assets and retain the install archive used by existing clients.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
./build.sh

compiler=${SUN_COMPILER:-sun}
build_root=$("$compiler" describe --config sun-config.json --field build_root)
package="$build_root/packages/sun_apple"
release=build/sun_apple-arm64-apple-darwin
install -m 644 "$package/lib/sun_apple.moon" "$release.moon"
install -m 644 "$package.tar.gz" "$release.sun.tar.gz"

# The older install archive uses lib/sun and lib rather than the Sun package layout.
prefix=build/package
rm -rf "$prefix"
mkdir -p "$prefix/lib/sun" "$prefix/share"
cp "$package/lib/sun_apple.moon" "$prefix/lib/sun/"
cp -R "$package/lib/native/." "$prefix/lib/"
cp -R "$package/share/sun_apple" "$prefix/share/"
"$compiler" --version > "$prefix/share/sun_apple/sun-version.txt"
tar -C "$prefix" -czf "$release.tar.gz" .
shasum -a 256 "$release.tar.gz" > "$release.tar.gz.sha256"
