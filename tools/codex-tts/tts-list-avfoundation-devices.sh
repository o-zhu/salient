#!/usr/bin/env bash
set -euo pipefail

if ! command -v ffmpeg >/dev/null 2>&1; then
  echo "Missing ffmpeg. Install with: brew install ffmpeg" >&2
  exit 127
fi

ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 </dev/null \
  | sed -n '/AVFoundation video devices:/,$p'

cat <<'TIP'

Tip:
  For an audio device index N, set:
    export TTS_AVFOUNDATION_INPUT=":N"

  Example:
    TTS_AVFOUNDATION_INPUT=":3" ./tools/codex-tts/tts-smoke-test.sh
TIP
