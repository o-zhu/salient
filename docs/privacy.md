# Privacy

## Default reader

The reader app, **Salient**, runs speech on your Mac. Pocket TTS and Apple
voices process your text locally. Salient has no telemetry, analytics, or cloud
inference. Contributions must not add any of these.

A packaged app includes the Pocket worker and stock model, so it can read aloud
without a network connection. The worker itself contains no networking code.

## Network access you choose

These features use the network only when you start them:

| What | When | Destination |
|---|---|---|
| Qwen voice runtime and models | You choose to install Qwen in Speech settings | Python packages and Hugging Face model files |
| Optional word-alignment models | You choose to install them | Hugging Face |
| Pocket stock assets | Only if the bundled copy is missing, for example in raw `swift run` builds | Pinned public Hugging Face URLs, checksum-verified |
| Opening a site in your browser | You click the button | That site, through your own browser |

Downloaded models are stored under `~/Library/Application Support/Salient`.
They are not sent anywhere.

## Browser access

Browser actions target the front Safari or Chrome tab when you use a button or
shortcut. To use them:

1. Allow Salient to control your browser when macOS asks. You can change this
   later in System Settings → Privacy & Security → Automation.
2. Allow JavaScript from Apple Events:
   - **Safari:** In Settings → Advanced, turn on web developer features. Then
     choose Develop → Allow JavaScript from Apple Events.
   - **Chrome:** Choose View → Developer → Allow JavaScript from Apple Events.

Salient runs only its own bundled scripts, and only in the front tab. You can
turn browser access off at any time in System Settings.

## Microphone

Salient asks for microphone access only if you record a voice sample for Qwen
voice cloning. Recordings stay on your Mac.

## Repository hygiene

This repository must never contain personal study content, screenshots,
recordings, model weights, logs, or credentials. Run
`python3 script/check_public_source.py --staged` before you commit.
