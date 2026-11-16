#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
usage: TTS_OUT=.tts-captures/test.wav ./tools/codex-tts/tts-capture.sh -- command [args...]

Runs a command that plays TTS/audio while routing macOS default output to the
Loopback device named by TTS_DEVICE, records the actual Core Audio output,
restores the previous output devices, and runs tts-analyze.py.

Important environment variables:
  TTS_DEVICE                 default: Codex TTS Sink
  TTS_RECORDER               default: auto ; auto|sox|ffmpeg (auto prefers SoX)
  TTS_AVFOUNDATION_INPUT     ffmpeg only; default: :$TTS_DEVICE
  TTS_OUT                    default: .tts-captures/tts-capture-<timestamp>.wav
  TTS_MAX_SECONDS            default: 120
  TTS_COMMAND_MAX_SECONDS    default: TTS_MAX_SECONDS
  TTS_PREROLL                default: 0.5
  TTS_TAIL                   default: 1.0
  TTS_ANALYZE                default: 1 ; set 0 to skip analyzer
  TTS_CAPTURE_LOCK_WAIT      default: 1 ; seconds to wait for another capture
USAGE
}

if [[ "${1:-}" == "--help" || $# -eq 0 ]]; then
  usage
  exit $([[ "${1:-}" == "--help" ]] && echo 0 || echo 2)
fi

if [[ "${1:-}" == "--" ]]; then
  shift
fi

if [[ $# -eq 0 ]]; then
  usage
  exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEVICE="${TTS_DEVICE:-Codex TTS Sink}"
CAPTURE_ROOT="${TTS_CAPTURE_ROOT:-.tts-captures}"
TIMESTAMP="$(date +%Y%m%d-%H%M%S)"
RUN_ID="${TTS_RUN_ID:-$TIMESTAMP-$$-$RANDOM}"
OUT="${TTS_OUT:-$CAPTURE_ROOT/tts-capture-$RUN_ID.wav}"
MAX_SECONDS="${TTS_MAX_SECONDS:-120}"
COMMAND_MAX_SECONDS="${TTS_COMMAND_MAX_SECONDS:-$MAX_SECONDS}"
PREROLL="${TTS_PREROLL:-0.5}"
TAIL="${TTS_TAIL:-1.0}"
ANALYZE="${TTS_ANALYZE:-1}"
ANALYZER="${TTS_ANALYZER:-$SCRIPT_DIR/tts-analyze.py}"
AVF_INPUT="${TTS_AVFOUNDATION_INPUT:-:$DEVICE}"
RECORDER_KIND="${TTS_RECORDER:-auto}"
RECORDER_WAS_AUTO=0
RECORDER_LOG="${TTS_RECORDER_LOG:-${TTS_FFMPEG_LOG:-${OUT%.*}.recorder.log}}"
RESTORE_AUDIO="${TTS_RESTORE_AUDIO:-1}"
LOCK_WAIT="${TTS_CAPTURE_LOCK_WAIT:-1}"
LOCK_FILE="${TTS_CAPTURE_LOCK_FILE:-${TMPDIR:-/tmp}/salient-codex-tts-capture.lock}"
TIMEOUT_RUNNER="$SCRIPT_DIR/tts-run-with-timeout.py"

validate_decimal() {
  local name="$1"
  local value="$2"
  local allow_zero="$3"
  if [[ ! "$value" =~ ^([0-9]+([.][0-9]*)?|[.][0-9]+)$ ]]; then
    echo "Invalid $name '$value'; expected a nonnegative number." >&2
    return 1
  fi
  if [[ "$allow_zero" != "1" ]] && ! awk -v value="$value" 'BEGIN { exit !(value > 0) }'; then
    echo "Invalid $name '$value'; expected a number greater than zero." >&2
    return 1
  fi
}

validate_decimal TTS_MAX_SECONDS "$MAX_SECONDS" 0 || exit 2
validate_decimal TTS_COMMAND_MAX_SECONDS "$COMMAND_MAX_SECONDS" 0 || exit 2
validate_decimal TTS_PREROLL "$PREROLL" 1 || exit 2
validate_decimal TTS_TAIL "$TAIL" 1 || exit 2
if [[ ! "$LOCK_WAIT" =~ ^[0-9]+$ ]]; then
  echo "Invalid TTS_CAPTURE_LOCK_WAIT '$LOCK_WAIT'; expected a nonnegative whole number of seconds." >&2
  exit 2
fi

if [[ "${TTS_CAPTURE_LOCK_HELD:-0}" != "1" ]]; then
  mkdir -p "$(dirname "$LOCK_FILE")"
  export TTS_CAPTURE_LOCK_HELD=1
  exec /usr/bin/lockf -t "$LOCK_WAIT" "$LOCK_FILE" "$0" "$@"
fi
unset TTS_CAPTURE_LOCK_HELD

mkdir -p "$(dirname "$OUT")"

if ! command -v SwitchAudioSource >/dev/null 2>&1; then
  echo "Missing SwitchAudioSource. Install with: brew install switchaudio-osx" >&2
  exit 127
fi

sox_supports_coreaudio_input() {
  local format_info=""
  command -v sox >/dev/null 2>&1 || return 1
  # Some SoX builds print valid format capabilities but still exit 1 for
  # --help-format, so capability is determined from the output itself.
  format_info="$(sox --help-format coreaudio 2>&1 || true)"
  grep -Eq '^Reads:[[:space:]]+yes$' <<<"$format_info"
}

case "$RECORDER_KIND" in
  auto)
    RECORDER_WAS_AUTO=1
    if sox_supports_coreaudio_input; then
      RECORDER_KIND="sox"
    else
      RECORDER_KIND="ffmpeg"
    fi
    ;;
  sox|ffmpeg) ;;
  *)
    echo "Invalid TTS_RECORDER '$RECORDER_KIND'; expected auto, sox, or ffmpeg." >&2
    exit 2
    ;;
esac
if ! command -v "$RECORDER_KIND" >/dev/null 2>&1; then
  echo "Missing $RECORDER_KIND. Install it with Homebrew before capturing TTS audio." >&2
  exit 127
fi
if [[ "$RECORDER_KIND" == "sox" ]] && ! sox_supports_coreaudio_input; then
  echo "This SoX build cannot read Core Audio devices; reinstall SoX with Core Audio support or use TTS_RECORDER=ffmpeg." >&2
  exit 127
fi

if [[ "$ANALYZE" != "0" ]] && [[ ! -x "$ANALYZER" ]]; then
  echo "Analyzer not found or not executable: $ANALYZER" >&2
  exit 127
fi
if [[ ! -f "$TIMEOUT_RUNNER" ]]; then
  echo "Command timeout helper not found: $TIMEOUT_RUNNER" >&2
  exit 127
fi

PREV_OUTPUT="$(SwitchAudioSource -c -t output 2>/dev/null || true)"
PREV_SYSTEM="$(SwitchAudioSource -c -t system 2>/dev/null || true)"
PREV_OUTPUT_UID="$(SwitchAudioSource -c -f json -t output 2>/dev/null | sed -nE 's/.*"uid": "([^"]+)".*/\1/p')"
PREV_SYSTEM_UID="$(SwitchAudioSource -c -f json -t system 2>/dev/null | sed -nE 's/.*"uid": "([^"]+)".*/\1/p')"
RESTORED=0
OUTPUT_AUDIO_ROUTED=0
SYSTEM_AUDIO_ROUTED=0
AUDIO_RESTORE_ATTEMPTS=4
AUDIO_RESTORE_RETRY_DELAY_SECONDS=0.15

current_audio_device_for_role() {
  local role="$1"
  SwitchAudioSource -c -t "$role" 2>/dev/null || true
}

route_audio_role() {
  local role="$1"
  local target_device="$2"
  local attempt=1
  local current_device=""

  while [[ "$attempt" -le "$AUDIO_RESTORE_ATTEMPTS" ]]; do
    SwitchAudioSource -t "$role" -s "$target_device" >/dev/null 2>&1 || true
    current_device="$(current_audio_device_for_role "$role")"
    if [[ "$current_device" == "$target_device" ]]; then
      return 0
    fi
    if [[ "$attempt" -lt "$AUDIO_RESTORE_ATTEMPTS" ]]; then
      sleep "$AUDIO_RESTORE_RETRY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done

  echo "ERROR: Failed to route macOS $role audio to '$target_device' after $AUDIO_RESTORE_ATTEMPTS attempts (current: ${current_device:-unknown}); refusing to start TTS." >&2
  return 1
}

restore_audio_role() {
  local role="$1"
  local previous_device="$2"
  local previous_uid="$3"
  local attempt=1
  local current_device=""

  if [[ -z "$previous_device" ]]; then
    current_device="$(current_audio_device_for_role "$role")"
    echo "ERROR: Cannot restore macOS $role audio: the pre-capture device was not recorded (current: ${current_device:-unknown})." >&2
    if [[ "$current_device" == "$DEVICE" ]]; then
      echo "ERROR: Codex TTS Sink is still selected for macOS $role audio." >&2
    fi
    return 1
  fi

  while [[ "$attempt" -le "$AUDIO_RESTORE_ATTEMPTS" ]]; do
    if [[ -n "$previous_uid" ]]; then
      SwitchAudioSource -t "$role" -u "$previous_uid" >/dev/null 2>&1 || true
    else
      SwitchAudioSource -t "$role" -s "$previous_device" >/dev/null 2>&1 || true
    fi
    current_device="$(current_audio_device_for_role "$role")"
    if [[ "$current_device" == "$previous_device" ]]; then
      return 0
    fi
    if [[ "$attempt" -lt "$AUDIO_RESTORE_ATTEMPTS" ]]; then
      sleep "$AUDIO_RESTORE_RETRY_DELAY_SECONDS"
    fi
    attempt=$((attempt + 1))
  done

  echo "ERROR: Failed to restore macOS $role audio to '$previous_device' after $AUDIO_RESTORE_ATTEMPTS attempts (current: ${current_device:-unknown})." >&2
  if [[ "$current_device" == "$DEVICE" ]]; then
    echo "ERROR: Codex TTS Sink is still selected for macOS $role audio; select the intended device manually." >&2
  fi
  return 1
}

restore_audio() {
  if [[ "$RESTORED" -eq 1 ]]; then
    return 0
  fi
  if [[ "$RESTORE_AUDIO" == "0" ]]; then
    local current_output
    local current_system
    current_output="$(current_audio_device_for_role output)"
    current_system="$(current_audio_device_for_role system)"
    echo "WARNING: TTS_RESTORE_AUDIO=0; macOS audio restoration was intentionally skipped (output: ${current_output:-unknown}, system: ${current_system:-unknown})." >&2
    RESTORED=1
    return 0
  fi
  local restore_status=0
  if [[ "$OUTPUT_AUDIO_ROUTED" -eq 1 ]]; then
    if ! restore_audio_role output "$PREV_OUTPUT" "$PREV_OUTPUT_UID"; then
      restore_status=1
    fi
  fi
  if [[ "$SYSTEM_AUDIO_ROUTED" -eq 1 ]]; then
    if ! restore_audio_role system "$PREV_SYSTEM" "$PREV_SYSTEM_UID"; then
      restore_status=1
    fi
  fi
  RESTORED=1
  return "$restore_status"
}

REC_PID=""
CMD_PID=""
REC_STATUS=0
CMD_STATUS=0
REC_INTERRUPTED=0
REC_SHUTDOWN_FORCED=0

process_is_running() {
  local pid="$1"
  local state=""
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" >/dev/null 2>&1 || return 1
  state="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')"
  [[ "$state" != Z* ]]
}

wait_for_process_exit() {
  local pid="$1"
  local attempts="${2:-20}"
  local attempt=0
  while [[ "$attempt" -lt "$attempts" ]]; do
    if ! process_is_running "$pid"; then
      return 0
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  ! process_is_running "$pid"
}

stop_command_runner() {
  local pid="${CMD_PID:-}"
  local status=0
  [[ -n "$pid" ]] || return 0

  if process_is_running "$pid"; then
    kill -TERM "$pid" >/dev/null 2>&1 || true
    # The timeout runner synchronously gives its child process group two seconds
    # for TERM and another two seconds after KILL. Do not kill the runner before
    # it has completed that group cleanup.
    if ! wait_for_process_exit "$pid" 120; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
      wait_for_process_exit "$pid" 20 || true
    fi
  fi
  if wait "$pid" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  CMD_STATUS="$status"
  CMD_PID=""
}

stop_recorder() {
  local pid="${REC_PID:-}"
  local status=0
  [[ -n "$pid" ]] || return 0

  if process_is_running "$pid"; then
    if kill -INT "$pid" >/dev/null 2>&1; then
      REC_INTERRUPTED=1
    fi
    if ! wait_for_process_exit "$pid" 20; then
      REC_SHUTDOWN_FORCED=1
      kill -TERM "$pid" >/dev/null 2>&1 || true
      if ! wait_for_process_exit "$pid" 20; then
        kill -KILL "$pid" >/dev/null 2>&1 || true
        wait_for_process_exit "$pid" 20 || true
      fi
    fi
  fi
  if wait "$pid" 2>/dev/null; then
    status=0
  else
    status=$?
  fi
  REC_STATUS="$status"
  REC_PID=""
}

cleanup_on_exit() {
  local original_status=$?
  local restore_status=0
  trap - EXIT
  trap '' INT TERM
  set +e
  stop_command_runner
  stop_recorder
  restore_audio
  restore_status=$?
  if [[ "$restore_status" -ne 0 && "$original_status" -eq 0 ]]; then
    original_status=1
  fi
  exit "$original_status"
}

handle_signal() {
  local signal_name="$1"
  local exit_status="$2"
  trap - EXIT
  trap '' INT TERM
  set +e
  echo "Interrupted by $signal_name; terminating capture processes and restoring audio." >&2
  stop_command_runner
  stop_recorder
  if ! restore_audio; then
    echo "ERROR: Audio restoration also failed while handling $signal_name." >&2
  fi
  exit "$exit_status"
}

trap cleanup_on_exit EXIT
trap 'handle_signal INT 130' INT
trap 'handle_signal TERM 143' TERM

# Route normal app audio and system alert audio to the virtual sink.
if [[ -z "$PREV_OUTPUT" ]]; then
  echo "ERROR: Could not determine the current macOS output device; refusing to switch audio without a restore target." >&2
  exit 1
fi
OUTPUT_AUDIO_ROUTED=1
if ! route_audio_role output "$DEVICE"; then
  exit 1
fi
if [[ -n "$PREV_SYSTEM" ]]; then
  SYSTEM_AUDIO_ROUTED=1
  if ! route_audio_role system "$DEVICE"; then
    exit 1
  fi
else
  echo "WARNING: Could not determine the current macOS system-audio device; system audio will not be rerouted." >&2
fi

rm -f "$OUT" "$RECORDER_LOG"

start_recorder() {
  REC_STATUS=0
  REC_INTERRUPTED=0
  REC_SHUTDOWN_FORCED=0
  if [[ "$RECORDER_KIND" == "sox" ]]; then
    # ffmpeg's AVFoundation input can omit Core Audio packets while preserving
    # their timestamps, which compresses the WAV and creates false block-edge
    # discontinuities. SoX's Core Audio driver preserves every device frame.
    sox -q -t coreaudio "$DEVICE" \
      -b 16 -c 2 -r 48000 "$OUT" \
      trim 0 "$MAX_SECONDS" \
      >>"$RECORDER_LOG" 2>&1 &
  else
    ffmpeg -hide_banner -nostdin -y \
      -thread_queue_size 4096 \
      -f avfoundation -i "$AVF_INPUT" \
      -t "$MAX_SECONDS" \
      -ac 2 -ar 48000 -c:a pcm_s16le "$OUT" \
      >>"$RECORDER_LOG" 2>&1 &
  fi
  REC_PID=$!
}

wait_for_recorder_readiness() {
  local attempt=0
  sleep "$PREROLL"
  while [[ "$attempt" -lt 10 ]]; do
    process_is_running "$REC_PID" || return 1
    if [[ -e "$OUT" ]]; then
      sleep 0.05
      process_is_running "$REC_PID"
      return $?
    fi
    sleep 0.02
    attempt=$((attempt + 1))
  done
  return 1
}

start_recorder
if ! wait_for_recorder_readiness; then
  failed_recorder_kind="$RECORDER_KIND"
  stop_recorder
  if [[ "$RECORDER_WAS_AUTO" -eq 1 && "$failed_recorder_kind" == "sox" ]] \
    && command -v ffmpeg >/dev/null 2>&1; then
    printf '\nSoX recorder was not ready before TTS; retrying with ffmpeg.\n' >>"$RECORDER_LOG"
    rm -f "$OUT"
    RECORDER_KIND="ffmpeg"
    start_recorder
    if ! wait_for_recorder_readiness; then
      stop_recorder
      echo "ERROR: Neither the SoX recorder nor the ffmpeg fallback became ready; refusing to start TTS." >&2
      echo "$RECORDER_KIND recorder log: $RECORDER_LOG" >&2
      exit 1
    fi
  else
    echo "ERROR: $failed_recorder_kind recorder did not become ready; refusing to start TTS." >&2
    echo "$failed_recorder_kind recorder log: $RECORDER_LOG" >&2
    exit 1
  fi
fi

/usr/bin/env -u TTS_CAPTURE_LOCK_HELD \
  /usr/bin/python3 "$TIMEOUT_RUNNER" "$COMMAND_MAX_SECONDS" -- "$@" &
CMD_PID=$!
if wait "$CMD_PID"; then
  CMD_STATUS=0
else
  CMD_STATUS=$?
fi
CMD_PID=""

REC_WAS_RUNNING_AFTER_COMMAND=0
if process_is_running "$REC_PID"; then
  REC_WAS_RUNNING_AFTER_COMMAND=1
fi
sleep "$TAIL"

stop_recorder

if ! restore_audio; then
  trap - EXIT INT TERM
  exit 1
fi
trap - EXIT INT TERM

if [[ ! -s "$OUT" ]]; then
  echo "Recording failed or produced an empty file: $OUT" >&2
  echo "$RECORDER_KIND recorder log: $RECORDER_LOG" >&2
  if [[ -f "$RECORDER_LOG" ]]; then
    sed -n '1,220p' "$RECORDER_LOG" >&2
  fi
  exit 1
fi

if [[ "$REC_WAS_RUNNING_AFTER_COMMAND" -ne 1 ]]; then
  echo "Recorder exited before the wrapped command completed (status $REC_STATUS)." >&2
  echo "$RECORDER_KIND recorder log: $RECORDER_LOG" >&2
  exit 1
fi

if [[ "$REC_SHUTDOWN_FORCED" -eq 1 ]]; then
  echo "Recorder required TERM/KILL escalation during shutdown." >&2
  echo "$RECORDER_KIND recorder log: $RECORDER_LOG" >&2
  exit 1
fi

if [[ "$REC_STATUS" -ne 0 && "$REC_INTERRUPTED" -ne 1 ]]; then
  echo "Recorder failed unexpectedly with status $REC_STATUS." >&2
  echo "$RECORDER_KIND recorder log: $RECORDER_LOG" >&2
  exit "$REC_STATUS"
fi

printf 'Captured WAV: %s\n' "$OUT"
printf '%s recorder log: %s\n' "$RECORDER_KIND" "$RECORDER_LOG"

ANALYZE_STATUS=0
if [[ "$ANALYZE" != "0" ]]; then
  set +e
  "$ANALYZER" "$OUT"
  ANALYZE_STATUS=$?
  set -e
fi

if [[ "$CMD_STATUS" -ne 0 ]]; then
  echo "Wrapped command exited with status $CMD_STATUS" >&2
  exit "$CMD_STATUS"
fi

if [[ "$ANALYZE_STATUS" -ne 0 ]]; then
  echo "Audio analyzer exited with status $ANALYZE_STATUS" >&2
  exit "$ANALYZE_STATUS"
fi

# A nonzero recorder status is accepted only when this wrapper intentionally sent SIGINT.
exit 0
