# sun_apple

Sun bindings for Apple platform APIs, organized by framework. Currently supports
**Apple Silicon macOS**. Capture requires macOS 15.2 or later.

```sh
./build.sh
```

Requires Sun and Xcode Command Line Tools. Set `SUN_COMPILER` to select a compiler.
Builds `build/sun_apple.moon` and static/shared native libraries under `build/native`.
Runs tests through both the JIT and a standalone executable. Tests cover runtime
lookup, Core Foundation ownership, rectangle ABI, ImageIO, and region coordinates.
They do not request screen access.

## Modules

| Module | Coverage |
| --- | --- |
| `apple_objc` | Raw class and selector discovery |
| `apple_core_foundation` | Raw retain/release, strings, URLs, array access |
| `apple_core_graphics` | Geometry, image ownership and dimensions |
| `apple_image_io` | Raw image source decoding and destination encoding |
| `apple_foundation` | Owned Sun copies of UUIDs and standard media paths |
| `apple_appkit` | Region selection geometry |
| `apple_screen_capture` | Owned picker/stream sessions, PNG capture and silent MP4 recording |

Raw C declarations require `unsafe`: callers must honor pointer validity, buffer
sizes, ownership, and thread requirements. `Create`, `Copy`, and `Retain` results
carry ownership. Core Foundation and ImageIO objects use `CFRelease`; images use
`CGImageRelease`. Runtime class and selector handles are borrowed. Check nullable
results before use. Core Foundation's UTF-8 encoding identifier is `0x08000100`.
Target and layout assertions currently restrict the bundle to arm64 macOS.

## Capture sessions

`apple_screen_capture.Session` presents the system picker and optionally an
Escape-cancellable region overlay. Construct, use, and destroy it on the main
thread. Use one session at a time. `select(0)` selects a display, `select(1)` a
window, and `select(2)` an area within a display. Poll until `Event.Selected`,
then call `start(recording, cursor, path)`. Paths must be private output files.

For recordings, wait for `Event.Recording`, call `stop()`, and wait for
`Event.Finished` before reading the MP4. Screenshots finish with `Event.Screenshot`.
`Event.Cancelled` reports cancellation; errors are returned as `SystemResult`.
Closing a session suppresses callbacks and requests native stream shutdown.
Stop and await finalization before deleting a recording's files.

The native Objective-C layer in `src/native` adapts blocks, delegates, event-loop
pumping, and the AppKit overlay. Sun's FFI cannot currently express these directly.
Native callbacks queue events; they never invoke Sun code on native callback
threads. This is not a complete binding generator or a pure-Sun Objective-C runtime.

Application policy belongs in clients: countdowns, filenames, cancellation state,
FFmpeg conversion, and atomic publication are implemented by the Sun video editor.

## Linking and distribution

Apple frameworks remain system dependencies. JIT clients load
`libsun_apple_native.dylib`, allowing macOS to register its Objective-C classes.
Compiled clients link `libsun_apple_native.a` and the frameworks listed in
`build.sh`. Sun does not currently expose `-framework`, so the build emits an
object with Sun and links it with `xcrun clang++`.

`./scripts/package-macos.sh` builds and tests an installable
`build/sun_apple-arm64-apple-darwin.tar.gz`. It includes both native libraries,
the bundle, compiler provenance, and the MIT license.
