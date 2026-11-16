#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PHRASE="${*:-Codex TTS capture smoke test. This audio should be captured silently.}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
OUT="${TTS_OUT:-.tts-captures/smoke-test-$TIMESTAMP.wav}"

if ! command -v say >/dev/null 2>&1; then
  echo "The macOS 'say' command was not found." >&2
  exit 127
fi

TTS_OUT="$OUT" TTS_MAX_SECONDS="${TTS_MAX_SECONDS:-15}" \
  "$SCRIPT_DIR/tts-capture.sh" -- say "$PHRASE"
