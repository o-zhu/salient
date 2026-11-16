# Agent guide

Notes for coding agents and automation working in this repository.

## Layout

- `Package.swift` contains the single Swift package (macOS 14+).
- `Sources/SalientCore` is the shared engine. `Sources/Salient` is the SwiftUI
  app shell (library product `SalientExperience`).
- `SalientMiniLauncher` builds the **Salient** reader, product `SalientMini`.
  Keep its bundle ID `com.zhuou.salient.mini` and product name stable.
- `Native/PocketWorker` is the Rust Pocket TTS worker. Read `UPSTREAM.md`
  before you change it.
- `script/` holds the build, packaging, notices, and release scripts. Their
  tests are in `script/tests`.
- For more detail, see [docs/architecture.md](docs/architecture.md).
- This checkout contains only the public reader. Read
  [docs/verification.md](docs/verification.md) for the publication baseline.
  Update durable docs when behavior or release requirements change.

## Build and run

```sh
./script/build_and_run.sh build                 # dist/Salient.app (debug)
./script/build_and_run.sh package               # dist/Salient.app (release)
./script/build_pocket_runtime.sh --link-debug   # native worker for swift run/tests
./script/build_pocket_runtime.sh --test         # native tests, same compiler setup
```

Building requires Apple Silicon, Xcode 27 (Swift 6.4) with the Metal toolchain,
Rust, and CMake. The first build downloads about 226 MB of checksum-verified
public model files into `.build/`. A raw `swift run` build differs from the
packaged app; see [docs/building.md](docs/building.md).

## Test

```sh
swift test
python3 -m unittest discover -s script/tests
python3 script/check_public_source.py --staged
```

Report test results exactly as they happened. Never say a test passed if you
did not run it.

## Rules

- Do not add telemetry, analytics, or cloud inference. The reader runs speech
  on the Mac.
- Never commit study content, screenshots, recordings, model weights, logs,
  credentials, or machine-specific paths. Do not use Git LFS.
- Developer ID signing, notarization, and release uploads require an explicit
  maintainer request. Local builds use ad-hoc signing.
  `script/release.sh notarize` contacts Apple.
- Keep the third-party license notices and the CC BY 4.0 attribution.
- Keep private applications and their library, podcast, and local-LLM features
  outside this repository, including tests, resources, and Git history.
- Put reader features in `SalientCore` or the reader app shell; do not add
  another app edition or hidden private functionality.
