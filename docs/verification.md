# Reader verification

This repository contains only Salient, the public reader. Its internal product
name is `SalientMini` and its bundle ID is `com.zhuou.salient.mini`.

The app retains Pocket/Alba offline narration, Apple and optional Qwen voices,
RSVP reading, and guarded Safari/Chrome shortcuts. Private app launchers,
library/ingestion code, podcasts, local text models, and their resources and
tests are excluded from this source tree and its new public history.

## Automated checks

The [Source checks workflow](https://github.com/o-zhu/salient/actions/workflows/ci.yml)
checks publication boundaries, packaging scripts, Swift tests, the Salient
launcher, and the standalone Pocket runtime. It does not use Apple signing
credentials, contact the notarization service, or download model weights.

Native builds and tests use the same compiler environment through
`script/build_pocket_runtime.sh` and its `--test` mode. This prevents a CMake
cache reset from attempting to install a dependency into a system directory.
Helper shutdown uses monotonic deadlines; simulated-clock tests check delayed
scheduling, and real-process tests check termination and cancellation.

The two installed-Pocket integration tests remain opt-in. Raw build logs,
recordings, model assets, and local review evidence are not committed.

## Local validation — November 16, 2026

- Swift: 338 tests, 336 passed, 2 opt-in installed-runtime tests skipped.
- Packaging/publication Python checks: 34 passed.
- Native Pocket runtime: build followed by all 17 tests passed.
- Packaged debug app: built and passed signature/resource checks. Read,
  Shortcuts, Narration, and Permissions were inspected with synthetic text.
  A concurrently running app owned the global shortcuts; this check did not
  claim successful shortcut registration or exercise a real exam.
- Fresh-user offline synthesis: network access was denied and independently
  checked; Pocket used the bundled model/Alba assets, generated 11.12 seconds
  of audio, invoked no download, and copied no model into the fresh home.
  Synthesis was silent; this was not an audible playback check.

## Release boundary

Building source does not publish an installer or alter any existing Apple
submission. Signing, notarization, clean older-macOS device testing, and audible
playback checks remain separate release work.
