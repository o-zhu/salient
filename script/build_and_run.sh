#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
[[ "${SALIENT_EDITION:-mini}" == mini ]] || { echo "This repository builds only Salient." >&2; exit 2; }
APP_NAME="SalientMini"
DISPLAY_NAME="Salient"
BUNDLE_ID="com.zhuou.salient.mini"
APP_VERSION="${SALIENT_APP_VERSION:-0.1.0}"
APP_BUILD="${SALIENT_APP_BUILD:-1}"
MIN_SYSTEM_VERSION="14.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="${SALIENT_DIST_DIR:-$ROOT_DIR/dist}"
APP_BUNDLE="$DIST_DIR/$DISPLAY_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_RESOURCES="$APP_CONTENTS/Resources"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
ICON_NAME="Salient"
ICON_FILE="$ICON_NAME.icns"
ICON_SOURCE="$ROOT_DIR/Assets/AppIcon/$ICON_FILE"
CODE_SIGN_IDENTITY="${SALIENT_CODESIGN_IDENTITY:--}"
CODE_SIGN_REQUIREMENTS="${SALIENT_CODESIGN_REQUIREMENTS:-=designated => identifier \"$BUNDLE_ID\"}"
QWEN_RUNTIME_ROOT="${SALIENT_QWEN_RUNTIME_ROOT:-$HOME/Library/Application Support/Salient/QwenTTS}"
POCKET_ASSETS_TOOL="$ROOT_DIR/script/package_pocket_assets.py"
# Optional explicit folder of already-downloaded stock assets used to seed the
# .build/pocket-assets cache after full checksum checks. Never searched for.
POCKET_ASSETS_SOURCE="${SALIENT_POCKET_ASSETS_SOURCE:-}"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

usage() {
  cat >&2 <<USAGE
usage: $0 [run|--debug|--logs|--telemetry|--verify|build|package|--release]

  run          Build a debug app bundle and open it (default).
  --debug      Build a debug app bundle and launch it in LLDB.
  --logs       Build/open a debug app bundle and stream its process logs.
  --telemetry  Build/open a debug app bundle and stream its subsystem logs.
  --verify     Build a debug app bundle and run the launch-stability check.
  build        Build a debug app bundle without opening it.
  package      Build an optimized release app bundle without opening it.
  --release    Alias for package.
USAGE
}

case "$MODE" in
  run|--debug|debug|--logs|logs|--telemetry|telemetry|--verify|verify|build)
    BUILD_CONFIGURATION="debug"
    ;;
  package|--release|release)
    BUILD_CONFIGURATION="release"
    ;;
  --help|-h|help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

cd "$ROOT_DIR"

reject_forbidden_resource_artifacts() {
  local search_root="$1"
  local found=()

  # Full checksum validation of PocketTTS first. Only after it passes may the
  # scan below skip the two exact manifest weight paths; nothing else is exempt.
  python3 "$POCKET_ASSETS_TOOL" scan "$search_root" --require-pocket

  while IFS= read -r -d '' path; do
    found+=("$path")
  done < <(
    find "$search_root" \
      \( -name "__pycache__" -o -name "*.pyc" -o -name "*.wav" -o -name "*.m4a" -o -name "*.mp3" \
         -o -name "*.aiff" -o -name "*.caf" -o -name "*.sqlite*" -o -name "*.safetensors" \
         -o -name "*.gguf" -o -name "*.xctest" -o -name "*Tests.bundle" \) \
      ! \( -type f \( -path "$search_root/PocketTTS/assets/model.safetensors" \
                     -o -path "$search_root/PocketTTS/assets/alba.safetensors" \) \) \
      -print0
  )

  if (( ${#found[@]} > 0 )); then
    echo "Refusing to package generated or private resource artifacts:" >&2
    printf '  %s\n' "${found[@]}" >&2
    exit 1
  fi
}

embed_mlx_metal_library() {
  local source="${SALIENT_MLX_METALLIB_PATH:-}"

  # Swift 6.4's default build system compiles MLX shaders from the pinned source.
  # Prefer that exact-version library over a Python environment's unrelated MLX build.
  local native_library="$(dirname "$BUILD_BINARY")/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib"
  if [[ -z "$source" && -s "$native_library" ]]; then
    ln -s "mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib" "$APP_RESOURCES/mlx.metallib"
    ln -s "../Resources/mlx.metallib" "$APP_MACOS/mlx.metallib"
    return
  fi

  if [[ -z "$source" && -d "$QWEN_RUNTIME_ROOT/venv/lib" ]]; then
    source="$(find "$QWEN_RUNTIME_ROOT/venv/lib" \
      -type f -path "*/site-packages/mlx/lib/mlx.metallib" -print -quit)"
  fi

  if [[ -z "$source" || ! -s "$source" ]]; then
    echo "Cannot package native Qwen: mlx.metallib was not found." >&2
    echo "Install the local Qwen runtime or set SALIENT_MLX_METALLIB_PATH." >&2
    exit 1
  fi

  cp "$source" "$APP_RESOURCES/mlx.metallib"
  /usr/bin/xattr -c "$APP_RESOURCES/mlx.metallib"
  chmod 0644 "$APP_RESOURCES/mlx.metallib"
  ln -s "../Resources/mlx.metallib" "$APP_MACOS/mlx.metallib"
}

prepare_pocket_assets() {
  local args=(fetch)
  if [[ -n "$POCKET_ASSETS_SOURCE" ]]; then
    args+=(--source "$POCKET_ASSETS_SOURCE")
  fi
  python3 "$POCKET_ASSETS_TOOL" "${args[@]}"
}

# Building or packaging must not stop another installed edition or checkout.
# Before an interactive launch, quit only the executable at this output path.
case "$MODE" in
  build|package|--release|release) ;;
  *)
    while IFS= read -r pid; do
      [[ -n "$pid" ]] || continue
      if [[ "$(ps -p "$pid" -o comm=)" == "$APP_BINARY" ]]; then
        kill "$pid" 2>/dev/null || true
      fi
    done < <(pgrep -x "$APP_NAME" || true)
    ;;
esac

echo "Building $APP_NAME ($BUILD_CONFIGURATION)..."
"$ROOT_DIR/script/build_pocket_runtime.sh"
# Fail before replacing the app if the pinned stock assets cannot be verified.
prepare_pocket_assets
swift build --configuration "$BUILD_CONFIGURATION" --product "$APP_NAME"
BUILD_BINARY="$(swift build --configuration "$BUILD_CONFIGURATION" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES" "$APP_CONTENTS/Helpers"
cp "$ROOT_DIR/.build/pocket-runtime/release/salient-pocket-worker" "$APP_CONTENTS/Helpers/salient-pocket-worker"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"
cp "$ICON_SOURCE" "$APP_RESOURCES/$ICON_FILE"
# Copy only production resources. A test build leaves test bundles beside the app.
# Never discover shipment contents with a wildcard or from Application Support.
for RESOURCE_NAME in Salient_SalientCore mlx-swift_Cmlx swift-crypto_Crypto swift-transformers_Hub; do
  RESOURCE_BUNDLE="$(dirname "$BUILD_BINARY")/$RESOURCE_NAME.bundle"
  [[ -d "$RESOURCE_BUNDLE" ]] || continue
  cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"
done
[[ -d "$APP_RESOURCES/Salient_SalientCore.bundle" ]] || { echo "Missing core resources" >&2; exit 1; }
embed_mlx_metal_library
python3 "$ROOT_DIR/script/third_party_notices.py" "$APP_RESOURCES/Third-Party Notices.txt"
python3 "$ROOT_DIR/script/pocket_notices.py" "$APP_RESOURCES/Pocket Runtime Notices.txt"
# Pinned English/Alba stock assets, receipt and notices, read-only, before signing.
python3 "$POCKET_ASSETS_TOOL" embed "$APP_RESOURCES" --offline

reject_forbidden_resource_artifacts "$APP_RESOURCES"

cat >"$INFO_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_BUILD</string>
  <key>CFBundleIconFile</key>
  <string>$ICON_NAME</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_SYSTEM_VERSION</string>
  <key>NSAppleEventsUsageDescription</key>
  <string>$DISPLAY_NAME needs permission to control your selected browser (Safari or Chrome) so it can click Submit and read visible study text at your request.</string>
  <key>NSMicrophoneUsageDescription</key>
  <string>$DISPLAY_NAME needs microphone access only when you choose to record a local voice sample for Qwen voice cloning.</string>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
</dict>
</plist>
PLIST

for RESOURCE_BUNDLE in "$APP_RESOURCES/"*.bundle; do
  [[ -d "$RESOURCE_BUNDLE" ]] || continue
  if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
    /usr/bin/codesign --force --sign - "$RESOURCE_BUNDLE" >/dev/null
  else
    /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp "$RESOURCE_BUNDLE" >/dev/null
  fi
done
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - "$APP_CONTENTS/Helpers/salient-pocket-worker" >/dev/null
else
  /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    "$APP_CONTENTS/Helpers/salient-pocket-worker" >/dev/null
fi
if [[ "$CODE_SIGN_IDENTITY" == "-" ]]; then
  /usr/bin/codesign --force --sign - --requirements "$CODE_SIGN_REQUIREMENTS" "$APP_BUNDLE" >/dev/null
else
  /usr/bin/codesign --force --sign "$CODE_SIGN_IDENTITY" --timestamp --options runtime \
    --entitlements "$ROOT_DIR/Config/Salient.entitlements" "$APP_BUNDLE" >/dev/null
fi
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"
open_app() {
  if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_BUNDLE" >/dev/null
  fi
  /usr/bin/open -n "$APP_BUNDLE"
}

verify_app_stability() {
  local pid=""
  local attempt

  open_app
  for attempt in {1..20}; do
    pid="$(pgrep -nx "$APP_NAME" || true)"
    if [[ -n "$pid" ]]; then
      break
    fi
    sleep 0.25
  done
  if [[ -z "$pid" ]]; then
    echo "$APP_NAME did not launch." >&2
    exit 1
  fi

  for attempt in {1..60}; do
    if ! kill -0 "$pid" >/dev/null 2>&1; then
      echo "$APP_NAME exited during the 15-second launch verification." >&2
      exit 1
    fi
    sleep 0.25
  done
  echo "$APP_NAME remained running for the 15-second launch verification (pid $pid)."
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    verify_app_stability
    ;;
  build|package|--release|release)
    echo "Packaged $BUILD_CONFIGURATION app bundle at $APP_BUNDLE"
    ;;
esac
