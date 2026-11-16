# Architecture

Salient is one Swift package (see [`Package.swift`](../Package.swift)) plus a
native Rust helper.

## Layout

| Path | What it holds |
|---|---|
| `Sources/SalientCore` | Shared engine: speech backends, Pocket/Qwen runtimes, RSVP timing, browser automation, readiness checks, resources |
| `Sources/Salient` | SwiftUI reader app shell (library product `SalientExperience`) |
| `Sources/SalientMiniLauncher` | Entry point for **Salient**, the reader (`SalientScene()`) |
| `Sources/SalientAudioProbe`, `Sources/SalientReadQuestionProbe` | Local speech and browser-reading diagnostics |
| `Native/PocketWorker` | Rust adapter of Kyutai Pocket TTS 4.0.1 (see [UPSTREAM.md](../Native/PocketWorker/UPSTREAM.md)) |
| `Tests/SalientCoreTests` | Swift tests and synthetic fixtures |
| `script/` | Build, packaging, notices, and release scripts, with Python tests in `script/tests` |
| `tools/codex-tts` | Developer utilities for capturing speech through a Loopback audio device |
| `Config/`, `Assets/` | Signing entitlements and the app icon |

## Reader

The app shows Read, Shortcuts, Narration, and Permissions. It contains no
private app launcher or library, podcast, or local-LLM implementation.
The internal `SalientMini` product name and `com.zhuou.salient.mini` bundle ID
stay stable for existing installations.

## Speech

- **Pocket (default).** `salient-pocket-worker` runs as a separate process in
  `Contents/Helpers`. Salient talks to it with a small set of JSON messages,
  one per line, over stdin and stdout. The worker streams 24 kHz audio in
  chunks of 80 ms or less. It loads model files only from local paths, checks
  them against the same SHA-256 manifest that Swift uses
  (`Resources/pocket-assets.json`), and has no networking code.
- **Apple voices.** These use AVFoundation. Salient also falls back to them
  when Pocket is not available.
- **Qwen (optional).** This uses MLX through `mlx-audio-swift`, plus a Python
  helper runtime installed under Application Support. Both are set up only
  when the user asks.

## Browser shortcuts

Salient sends Apple Events to the front Safari or Chrome tab and runs bundled
JavaScript in that tab (`Resources/*.js`). Actions run when the user invokes a button or shortcut, and only after macOS
Automation consent is given. Supported-site checks require the selected front
tab to be an exact supported HTTPS host or the bundled synthetic fixture. The browser's
"Allow JavaScript from Apple Events" setting must also be on. See
[privacy.md](privacy.md#browser-access).
