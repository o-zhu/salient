# Third-party software and models

Salient's own source code is released under the [MIT License](LICENSE). That
license does not cover the models, voices, or third-party code listed below.
Each keeps its own license.

## Bundled in the packaged app

- **Kyutai Pocket TTS 4.0.1** (MIT). Salient adapts its Rust code in
  [`Native/PocketWorker`](Native/PocketWorker). The license is in
  [`LICENSE-Pocket`](Native/PocketWorker/LICENSE-Pocket), and
  [`UPSTREAM.md`](Native/PocketWorker/UPSTREAM.md) records the source and
  changes. The worker also uses xn-ptts and xn. Its dependencies are pinned in
  `Cargo.lock`. Some crates ship without license text, so copies of those
  licenses are kept in `Native/PocketWorker/licenses/`.
- **Pocket English stock model (October 2026) and Alba voice**, voiced by
  Alba MacKenna. Licensed under
  [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). These files are
  unchanged downloads from
  [kyutai/pocket-tts-without-voice-cloning](https://huggingface.co/kyutai/pocket-tts-without-voice-cloning).
  See the [voice attribution](https://huggingface.co/kyutai/tts-voices#alba-mackenna).
  Keep this attribution with the app and with any copy of the assets you share.
- **Swift packages** pinned in [`Package.resolved`](Package.resolved). These
  include mlx-audio-swift, mlx-swift, mlx-swift-lm, swift-transformers,
  swift-huggingface, swift-jinja, EventSource, yyjson, and Apple's
  swift-crypto, swift-nio, swift-collections, swift-syntax, and related
  packages.

Packaging generates the full license texts and places them in the app:

- `Contents/Resources/Third-Party Notices.txt`, made by
  `script/third_party_notices.py`.
- `Contents/Resources/Pocket Runtime Notices.txt`, made by
  `script/pocket_notices.py`.
- `Contents/Resources/PocketTTS/NOTICES.md`.

The source attribution is
[`Sources/SalientCore/Resources/Pocket-Notices.md`](Sources/SalientCore/Resources/Pocket-Notices.md).

## Not bundled

These are downloaded only when you ask for them. They are not redistributed
with Salient and are covered by their own licenses:

- Qwen voice models
- Word-alignment models
- The Python packages installed for the Qwen runtime

The default app does not include any gated voice-cloning model, Hugging Face
token, or custom reference voice sample.
