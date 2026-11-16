#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODE="${1:-build}"
case "$MODE" in
  build|--link-debug|--test) ;;
  *) echo "Usage: $0 [--link-debug|--test]" >&2; exit 2 ;;
esac
command -v cargo >/dev/null || { echo "Building Pocket requires Rust (brew install rust). End users do not need it." >&2; exit 1; }
command -v cmake >/dev/null || { echo "Building Pocket requires CMake (brew install cmake)." >&2; exit 1; }
[[ "$(uname -m)" == arm64 ]] || { echo "Salient Pocket currently targets Apple Silicon." >&2; exit 1; }
export MACOSX_DEPLOYMENT_TARGET=14.0
# Never compile for this developer Mac's M4 instruction set; support M1 onward.
export RUSTFLAGS="-C target-cpu=apple-m1"
export CARGO_TARGET_DIR="$ROOT/.build/pocket-runtime"
export CC="$(xcrun --find clang)"
export CXX="$(xcrun --find clang++)"
# Use the exact same C/C++ compiler for tests and builds. Changing it between
# commands makes CMake reset its cached install prefix to a system directory.
if [[ "$MODE" == "--test" ]]; then
  exec cargo test --release --locked --manifest-path "$ROOT/Native/PocketWorker/Cargo.toml"
fi
cargo build --release --locked --manifest-path "$ROOT/Native/PocketWorker/Cargo.toml"
WORKER="$CARGO_TARGET_DIR/release/salient-pocket-worker"
# Fail packaging if a Homebrew or other developer-only dylib slipped in.
if /usr/bin/otool -L "$WORKER" | tail -n +2 | awk '{print $1}' | /usr/bin/grep -Ev '^(/usr/lib/|/System/Library/)' ; then
  echo "Pocket must link only to system libraries." >&2
  exit 1
fi
/usr/bin/codesign --force --sign - "$WORKER"
"$WORKER" --version
if [[ "$MODE" == "--link-debug" ]]; then
  cd "$ROOT"
  DEBUG_BIN="$(swift build --configuration debug --show-bin-path)"
  mkdir -p "$DEBUG_BIN"
  cp "$WORKER" "$DEBUG_BIN/salient-pocket-worker"
fi
