# Building and testing

## Requirements

**To build:**

- An Apple Silicon Mac.
- Xcode 27 (Swift 6.4) with the Metal toolchain. The default Swift build
  system compiles the MLX shaders from the pinned source.
- Rust (`cargo`) and CMake, for the native Pocket worker.
- Python 3, for the packaging and test scripts.

**To run:** macOS 14 or later on Apple Silicon. Users do not need Rust,
Python, or any model downloads.

The macOS 14 target has not yet been tested on a clean older-OS device.

## Build the app

```sh
./script/build_and_run.sh            # debug build of dist/Salient.app, then open it
./script/build_and_run.sh build      # debug build, no launch
./script/build_and_run.sh package    # optimized (release) build, no launch
./script/build_and_run.sh --verify   # build, launch, and check it stays running for 15 s
./script/build_and_run.sh --help     # list all modes
```

The script builds **Salient** (internal product `SalientMini`). This repository
contains no other application edition.

Each build runs these steps:

1. Builds the native Pocket worker with `script/build_pocket_runtime.sh`.
2. Gets the pinned Pocket stock assets with `script/package_pocket_assets.py`.
   These are the English model, the tokenizer, and the Alba voice, about 226 MB
   in total. They come from public Hugging Face URLs fixed to one revision, and
   each file's SHA-256 is checked. They are cached in `.build/pocket-assets`.
   They are never stored in Git or Git LFS. After the first fetch, later builds
   reuse the cache. To seed the cache from files you already downloaded, set
   `SALIENT_POCKET_ASSETS_SOURCE=/path/to/folder`. Those files get the same
   checksum checks.
3. Runs `swift build` and puts together the `.app` bundle. The bundle contains
   the worker in `Contents/Helpers`, the stock assets, and license notices.
4. Refuses to package any audio, database, model file, or test artifact outside
   the approved list.
5. Signs the app. By default this is an ad-hoc signature for local use only.

A packaged app needs no network access on first launch to read aloud.

### `swift run` is not the packaged app

`swift run SalientMini` works for quick checks, but the result is not the same
as the packaged app. The Pocket worker and stock assets are not included. Pocket
may need to download its public assets, or Salient may fall back to Apple
voices. To make the native worker available to debug builds, run:

```sh
./script/build_pocket_runtime.sh --link-debug
```

## Tests

```sh
swift test                                          # Swift unit tests
python3 -m unittest discover -s script/tests        # packaging/release script tests
./script/build_pocket_runtime.sh --link-debug       # build and link the native worker
./script/build_pocket_runtime.sh --test             # native unit tests with the same compiler setup
python3 script/check_public_source.py --staged      # privacy check before committing
```

Pocket runtime tests are opt-in and require an already installed local Pocket
model. After building the helper, run
`SALIENT_TEST_POCKET_RUNTIME=1 swift test --filter PocketTTSTests`. These tests
generate speech without playing it or downloading anything.

To verify the packaged app with an empty user home and networking denied:

```sh
python3 script/check_pocket_bundle.py --app dist/Salient.app --out .build/offline-check
```

This check is silent. Actual playback checks must use a virtual audio device
through `tools/codex-tts/tts-capture.sh`, which restores the previous audio route.
Keep the resulting recordings and reports out of Git.

## Useful environment variables

| Variable | Purpose |
|---|---|
| `SALIENT_DIST_DIR` | Output folder (default `dist/`) |
| `SALIENT_APP_VERSION` / `SALIENT_APP_BUILD` | Version strings in `Info.plist` |
| `SALIENT_POCKET_ASSETS_SOURCE` | An existing folder to seed the asset cache from (checksums are still checked) |
| `SALIENT_CODESIGN_IDENTITY` | Signing identity; `-` (ad-hoc) by default. See [releasing.md](releasing.md) |
| `SALIENT_MLX_METALLIB_PATH` | Override the MLX shader library location |
