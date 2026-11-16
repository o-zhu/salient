# Native Pocket worker

This is Salient's offline adapter of **Kyutai Pocket TTS v4.0.1**, commit
`a922b912dfa366975294afb568d815b305acde5d`, released October 21, 2026.
The upstream Rust package still calls itself 3.3.0; the release tag, source
commit, and model manifest define our version, rather than that stale label.

Sources: <https://github.com/kyutai-labs/pocket-tts/tree/v4.0.1/rust>
and its MIT license in `LICENSE-Pocket`. The official Rust runtime pins
xn-ptts to `7efa26973f81bba42cf2ace8da2c1eb9b605d54d`; we retain that exact
revision. All registry dependencies and checksums are in Cargo.lock.

## Deliberate adaptations

- `config.rs`, `model.rs`, `rng.rs`, `text.rs`, `tokenizer.rs`, and `weights.rs`
  originate in the release's `rust/src`. The English config originates in
  `pocket_tts/config/english_2026-10.yaml`.
- Only the shipping English config is embedded. The drifting parser test uses
  a synthetic config instead of requiring the entire upstream model catalog.
- A bounded JSON-line stdin/stdout protocol replaces CLI/HTTP service code.
  Each 24 kHz float32 PCM event carries at most 1,920 samples (80 ms).
- Downloads, HTTP, HF auth, voice cloning, microphone/audio device access,
  playback, and telemetry are absent from the worker. The local-only loader
  rejects URL/relative inputs. Swift downloads public stock assets separately.
- The worker checks the same SHA-256 manifest embedded in Swift before loading.
  Model and Alba embedding both use the October checkpoint revision; the
  release's older default voice URL does not provide the matching October state.
- Generation and decoding run concurrently with an eight-frame bounded channel.
  The upstream five-millisecond onset fade and number/punctuation handling stay.
- Both int8 and float32 backends are available for controlled comparison. Salient
  uses int8, four Rayon workers, one Accelerate thread, and cached voice state.
- Standalone 3–9 digit integers receive explicit English cardinal pronunciation
  after a reproducible 132 → 32 omission in both precision modes. Decimal
  components, grouped/leading-zero numbers and identifiers stay unchanged.
  Displayed/source text is never rewritten.
- `--version` exposes upstream version and protocol version. Failures are generic
  and never echo source text. The process is also denied network by macOS.

## Build and verify

Developer tools only: Rust, CMake, Xcode command-line tools. End users need none.
Run `./script/build_pocket_runtime.sh --link-debug` from the repo before opt-in
runtime tests or probes. The app packaging script builds and embeds the
helper at `Contents/Helpers/salient-pocket-worker`, sign it before the outer app,
and reject non-system dylibs. The deployment target is macOS 14, with M1 CPU
instructions, rather than the build machine's instruction set.

The build uses `--locked`. Rust tests cover the upstream text/config/weight
logic and private protocol validation. App tests exercise actual offline
streaming, cancellation, restart, installer locking, atomic activation, and
checksum failures. Use the Loopback wrapper for any playback tests.

`script/pocket_notices.py` creates notices for the complete resolved native
build graph, including bundled C++ license files and the Rust standard library.
Some crates omit license text from their tarball. The copies in `licenses/`
come from the upstream repo at each crate's `.cargo_vcs_info.json` revision:

| Crate | Commit |
|---|---|
| dasp_frame | 221b81038c528bf3fc364a8ab5cc4b2e52f7dbfc |
| dasp_sample | 97c3bb9b2363c0b46ac1633858bf1054fd02a980 |
| pulp-wasm-simd-flag | 5eb07fd7b68edf0a5e19f71737d315f72a510295 |
| sentencepiece | ff5626ae0058103e16244b35772d6bb1d655a6df |
| xn | 878928e6bc9e10686b3bcd5dd422ae81f54c24cb |

Do not copy model weights, generated audio, or Python environments into this
folder. Release updates require a new model manifest, pinned source review,
real playback/cancellation checks, and rebuilding Salient.
