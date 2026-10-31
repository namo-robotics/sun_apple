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
They do not request screen, camera, or microphone access. A native movie test
feeds synthetic pixels and audio through the actual live writer and decodes its
output to check placement, camera updates over a still desktop, and the audio track.
The encoder test requires macOS media-service access, so it cannot run inside a
sandbox that blocks those services. `build/movie-tests --stress` runs a longer
1080p synthetic capture for memory profiling.

## Modules

| Module | Coverage |
| --- | --- |
| `apple_objc` | Raw class and selector discovery |
| `apple_core_foundation` | Raw retain/release, strings, URLs, array access |
| `apple_core_graphics` | Geometry, image ownership and dimensions |
| `apple_image_io` | Raw image source decoding and destination encoding |
| `apple_foundation` | Owned Sun copies of UUIDs and standard media paths |
| `apple_appkit` | Region selection geometry |
| `apple_screen_capture` | Owned picker/stream sessions, PNG capture and live H.264/AAC MP4 recording |

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
then call `start(recording, cursor, path)` for screenshots or legacy silent capture.
Use `start_live(cursor, path, camera, microphone, corner, size)` for live MP4
recording. Corner values select lower right, lower left, upper right, and upper
left; size values select small, medium, and large. Paths must be private output files.

For recordings, wait for `Event.Recording`, call `stop()`, and wait for
`Event.Finished` before reading the MP4. Screenshots finish with `Event.Screenshot`.
`Event.Cancelled` reports cancellation; errors are returned as `SystemResult`.
Live recording uses one latest desktop frame and one latest camera frame, a
bounded pixel-buffer pool, and a serial encoder queue. A host-clock timer keeps
camera motion visible over an unchanged desktop. H.264 video and optional AAC
microphone audio are written as MP4 fragments during capture. Device access is
requested only for enabled inputs. Clients must embed camera and microphone usage
descriptions. Camera frames may be dropped under encoding backpressure; audio
write failures are reported.

Closing a session suppresses callbacks and stops camera and streaming resources.
Closing an unfinished AVAssetWriter can remove its output pathname. Clients that
want to retain partial fragments after an error must create a recovery hard link
before closing the session.
Stop and await finalization before deleting a recording's files.

The native Objective-C layer in `src/native` adapts blocks, delegates, event-loop
pumping, and the AppKit overlay. Sun's FFI cannot currently express these directly.
Native callbacks queue events; they never invoke Sun code on native callback
threads. This is not a complete binding generator or a pure-Sun Objective-C runtime.

Application policy belongs in clients: countdowns, filenames, cancellation state,
failure recovery and atomic publication are implemented by the Sun video editor.

## Linking and distribution

Apple frameworks remain system dependencies. JIT clients load
`libsun_apple_native.dylib`, allowing macOS to register its Objective-C classes.
Compiled clients link `libsun_apple_native.a` and the frameworks listed in
`build.sh`. Sun does not currently expose `-framework`, so the build emits an
object with Sun and links it with `xcrun clang++`.

`./scripts/package-macos.sh` builds and tests an installable
`build/sun_apple-arm64-apple-darwin.tar.gz`. It includes both native libraries,
the bundle, compiler provenance, and the MIT license.
