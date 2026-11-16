#!/usr/bin/env bash
set -u -o pipefail

DEVICE="${TTS_DEVICE:-Codex TTS Sink}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ERRORS=0
WARNINGS=0

ok() { printf '✅ %s\n' "$*"; }
warn() { printf '⚠️  %s\n' "$*"; WARNINGS=$((WARNINGS + 1)); }
fail() { printf '❌ %s\n' "$*"; ERRORS=$((ERRORS + 1)); }
section() { printf '\n## %s\n' "$*"; }

section "Codex TTS capture doctor"
printf 'Target Loopback device: %s\n' "$DEVICE"
printf 'Working directory: %s\n' "$(pwd)"
printf 'Script directory: %s\n' "$SCRIPT_DIR"
printf 'macOS version: %s\n' "$(sw_vers -productVersion 2>/dev/null || echo unknown)"

section "Required commands"
if command -v SwitchAudioSource >/dev/null 2>&1; then
  ok "SwitchAudioSource found: $(command -v SwitchAudioSource)"
else
  fail "SwitchAudioSource missing. Install with: brew install switchaudio-osx"
fi

if command -v ffmpeg >/dev/null 2>&1; then
  ok "ffmpeg found: $(command -v ffmpeg)"
else
  fail "ffmpeg missing. Install with: brew install ffmpeg"
fi

if command -v python3 >/dev/null 2>&1; then
  ok "python3 found: $(command -v python3)"
  python3 --version 2>&1 | sed 's/^/   /'
  if python3 -m py_compile "$SCRIPT_DIR/tts-analyze.py" >/dev/null 2>&1; then
    ok "tts-analyze.py syntax check passed"
  else
    fail "tts-analyze.py syntax check failed"
  fi
else
  fail "python3 missing"
fi

section "SwitchAudioSource devices"
if command -v SwitchAudioSource >/dev/null 2>&1; then
  CURRENT_OUTPUT="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
  CURRENT_SYSTEM="$(SwitchAudioSource -c -t system 2>/dev/null || true)"
  printf 'Current output device: %s\n' "${CURRENT_OUTPUT:-unknown}"
  printf 'Current system device: %s\n' "${CURRENT_SYSTEM:-unknown}"

  OUTPUT_DEVICES="$(SwitchAudioSource -a -t output 2>/dev/null || true)"
  INPUT_DEVICES="$(SwitchAudioSource -a -t input 2>/dev/null || true)"

  printf '\nOutput devices:\n'
  printf '%s\n' "$OUTPUT_DEVICES" | sed 's/^/  - /'
  printf '\nInput devices:\n'
  printf '%s\n' "$INPUT_DEVICES" | sed 's/^/  - /'

  if printf '%s\n' "$OUTPUT_DEVICES" | grep -Fxq "$DEVICE"; then
    ok "Device appears as a macOS output device"
  else
    fail "Device does not appear as a macOS output device: $DEVICE"
  fi

  if printf '%s\n' "$INPUT_DEVICES" | grep -Fxq "$DEVICE"; then
    ok "Device appears as a macOS input device"
  else
    warn "Device was not listed by SwitchAudioSource as an input. ffmpeg may still see it via AVFoundation; check the next section."
  fi
fi

section "ffmpeg AVFoundation audio devices"
if command -v ffmpeg >/dev/null 2>&1; then
  AVF_OUTPUT="$(ffmpeg -hide_banner -f avfoundation -list_devices true -i "" 2>&1 </dev/null || true)"
  printf '%s\n' "$AVF_OUTPUT" | sed -n '/AVFoundation audio devices:/,$p' | sed 's/^/  /'
  if printf '%s\n' "$AVF_OUTPUT" | grep -Fq "$DEVICE"; then
    ok "Device appears in ffmpeg AVFoundation audio devices"
  else
    warn "Device name was not found in ffmpeg AVFoundation output. Use ./tools/codex-tts/tts-list-avfoundation-devices.sh and set TTS_AVFOUNDATION_INPUT=":<index>" if needed."
  fi
fi

section "macOS permissions reminder"
cat <<'REMINDER'
If capture fails with an AVFoundation permission or device-open error, grant Microphone permission to the terminal app that runs Codex:
System Settings -> Privacy & Security -> Microphone
REMINDER

section "Summary"
if [[ "$ERRORS" -gt 0 ]]; then
  printf 'Doctor found %d error(s) and %d warning(s).\n' "$ERRORS" "$WARNINGS"
  exit 1
fi
printf 'Doctor completed with %d warning(s).\n' "$WARNINGS"
exit 0
