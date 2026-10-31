# Development

- Run `./build.sh` from this repository to build the bundle and run tests.
- This initial binding set targets Apple Silicon macOS. Do not imply support for
  other Apple platforms until their ABI and availability checks are tested.
- Keep framework declarations separate. All raw native calls remain unsafe;
  document ownership and nullability before introducing safe wrappers.
- Use `sun fmt src tests` for first-party Sun sources.
- Keep generated artifacts in `build/` and temporary work in `tmp/`.
- Do not request screen access in automated tests.
- Follow the workspace documentation-comment and Git rules.
