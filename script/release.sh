#!/usr/bin/env bash
set -euo pipefail

# Apple uploads are confined to the explicit `notarize` command.
MODE="${1:-help}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ "${SALIENT_EDITION:-mini}" == mini ]] || { echo "This repository releases only Salient." >&2; exit 2; }
NAME="Salient"
BUNDLE_ID="com.zhuou.salient.mini"
DIST="${SALIENT_DIST_DIR:-$ROOT/dist}"
VERSION="${SALIENT_APP_VERSION:-0.1.0}"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Use a three-part version, e.g. 1.0.0" >&2; exit 2; }
APP="$DIST/$NAME.app"
ZIP="$DIST/$NAME-$VERSION-notarization.zip"
DMG="$DIST/$NAME-$VERSION.dmg"
IDENTITY="${SALIENT_CODESIGN_IDENTITY:-}"
PROFILE="${SALIENT_NOTARY_PROFILE:-SalientNotary}"
TEAM_ID="${SALIENT_TEAM_ID:-}"
NOTARY_APP="$DIST/$NAME-$VERSION-notary-app.json"
NOTARY_DMG="$DIST/$NAME-$VERSION-notary-dmg.json"

usage() {
  cat <<'USAGE'
Usage: script/release.sh check|preview|prepare|notarize

Builds Salient, the reader. SALIENT_DIST_DIR selects the output folder.
check      Read-only release-tool and certificate preflight.
preview    Build an ad-hoc development DMG. Not for distribution.
prepare    Build/sign the optimized app and make a notarization ZIP. No upload.
notarize   Submit the prepared ZIP, staple the app, make/sign/notarize/staple
           the DMG, and assess it. This command sends the binary to Apple.

prepare/notarize require SALIENT_CODESIGN_IDENTITY="Developer ID Application: ...".
notarize uses SALIENT_NOTARY_PROFILE (default SalientNotary), stored in Keychain.
Never put passwords, API keys, or signing private keys in this repository.
USAGE
}

require_identity() {
  [[ "$IDENTITY" == "Developer ID Application:"* ]] || {
    echo 'Set SALIENT_CODESIGN_IDENTITY to your Developer ID Application certificate.' >&2; exit 1;
  }
}

make_dmg() (
  local output="$1"
  local stage
  stage="$(mktemp -d "$DIST/.dmg-stage.XXXXXX")"
  trap 'rm -rf "$stage"' EXIT
  ditto "$APP" "$stage/$NAME.app"
  # Start Here promises bundled offline speech; check the exact copy being imaged.
  python3 "$ROOT/script/package_pocket_assets.py" verify-bundle "$stage/$NAME.app/Contents/Resources"
  ln -s /Applications "$stage/Applications"
  cat > "$stage/Start Here.txt" <<EOF
$NAME

1. Drag $NAME to Applications.
2. Open it from Applications.
3. Open Read, choose Try a sample, then Read aloud.

Pocket TTS with the Alba voice is included and ready offline. No model
download, account, or internet connection is needed to read aloud.

Browser study controls are set up separately: choose Safari or Chrome and
use Set shortcuts or Manage access in the Read workspace.

Requires an Apple Silicon Mac and macOS 14 or newer.
Speech and your text are processed on your Mac.

Includes Kyutai Pocket TTS 4.0.1 (MIT) with its English stock model and the
Alba voice by Alba MacKenna (CC BY 4.0). Attributions are inside the app at
Contents/Resources/PocketTTS/NOTICES.md, beside its third-party notices.
EOF
  if [[ "$MODE" == "preview" ]]; then
    printf '\nDEVELOPMENT PREVIEW: not Developer ID signed or notarized. Do not distribute.\n' >> "$stage/Start Here.txt"
  fi
  hdiutil create -volname "$NAME" -srcfolder "$stage" -ov -format UDZO "$output" >/dev/null
)

# Basename-only, so `shasum -c` works wherever the DMG and checksum travel together.
write_checksum() {
  local artifact="$1"
  (cd "$(dirname "$artifact")" && shasum -a 256 "$(basename "$artifact")" > "$(basename "$artifact").sha256")
}

artifact_hash() { shasum -a 256 "$1" | cut -d ' ' -f 1; }

verify_signed_app() {
  codesign --verify --deep --strict "$APP"
  local signature
  signature="$(codesign -dvvvv "$APP" 2>&1)"
  [[ "$signature" == *"Authority=Developer ID Application:"* ]] || {
    echo "Refusing to submit an app without a Developer ID signature." >&2; exit 1;
  }
  [[ "$signature" == *"Authority=$IDENTITY"* && "$signature" == *"(runtime)"* ]] || {
    echo "The app must use the selected Developer ID and hardened runtime." >&2; exit 1;
  }
  if [[ -n "$TEAM_ID" && "$signature" != *"TeamIdentifier=$TEAM_ID"* ]]; then
    echo "The app belongs to a different Apple team." >&2; exit 1
  fi
  python3 - "$APP" "$NAME" "$BUNDLE_ID" "$VERSION" <<'PY'
import pathlib, plistlib, sys
app, name, bundle_id, version = sys.argv[1:]
info = plistlib.loads((pathlib.Path(app) / "Contents/Info.plist").read_bytes())
for key, expected in [("CFBundleName", name), ("CFBundleDisplayName", name),
                      ("CFBundleIdentifier", bundle_id), ("CFBundleShortVersionString", version)]:
    if info.get(key) != expected:
        raise SystemExit(f"Refusing mismatched release: {key} = {info.get(key)!r}, expected {expected!r}")
PY
  python3 "$ROOT/script/package_pocket_assets.py" scan "$APP/Contents/Resources" --require-pocket
  APP_CDHASH="$(printf '%s\n' "$signature" | sed -n 's/^CDHash=//p')"
  [[ -n "$APP_CDHASH" ]] || { echo "Cannot read the signed app's code hash." >&2; exit 1; }
}

prepare_zip() {
  # Reuse only an archive sealed by this workflow from the same signed app.
  # This retains an in-flight submission when a previous wait was interrupted.
  if [[ -f "$ZIP" && -f "$ZIP.source-cdhash" && -f "$ZIP.sha256" ]] &&
      [[ "$(cat "$ZIP.source-cdhash")" == "$APP_CDHASH" ]] &&
      (cd "$DIST" && shasum -a 256 -c "$(basename "$ZIP").sha256" >/dev/null 2>&1); then
    return
  fi
  ditto -c -k --keepParent "$APP" "$ZIP"
  printf '%s\n' "$APP_CDHASH" > "$ZIP.source-cdhash"
  write_checksum "$ZIP"
}

submit_and_check() {
  local artifact="$1" report="$2" digest submission_id status
  digest="$(artifact_hash "$artifact")"
  submission_id=""
  if [[ -f "$report" && -f "$report.artifact-sha256" ]] &&
      [[ "$(cat "$report.artifact-sha256")" == "$digest" ]]; then
    submission_id="$(/usr/bin/plutil -extract id raw -o - "$report" 2>/dev/null || true)"
  fi
  if [[ -z "$submission_id" ]]; then
    # Persist Apple's submission ID before waiting. No credentials enter files.
    echo "Uploading $(basename "$artifact") to Apple..."
    xcrun notarytool submit "$artifact" --keychain-profile "$PROFILE" --no-wait --output-format json > "$report.tmp"
    submission_id="$(/usr/bin/plutil -extract id raw -o - "$report.tmp")"
    mv "$report.tmp" "$report"
    printf '%s\n' "$digest" > "$report.artifact-sha256"
  fi
  echo "Apple submission: $submission_id ($artifact)"
  xcrun notarytool info "$submission_id" --keychain-profile "$PROFILE" --output-format json > "$report.status.tmp"
  mv "$report.status.tmp" "$report"
  status="$(/usr/bin/plutil -extract status raw -o - "$report")"
  if [[ "$status" == "In Progress" ]]; then
    xcrun notarytool wait "$submission_id" --keychain-profile "$PROFILE" --output-format json > "$report.wait.tmp" || {
      echo "Apple submission is saved in $report. Rerun notarize to resume without uploading it again." >&2
      return 1
    }
    mv "$report.wait.tmp" "$report"
    status="$(/usr/bin/plutil -extract status raw -o - "$report")"
  fi
  xcrun notarytool log "$submission_id" --keychain-profile "$PROFILE" "$report.log.json" ||
    echo "Could not fetch Apple's detailed log yet; submission status is $status." >&2
  [[ "$status" == "Accepted" ]] || {
    echo "Apple did not accept this submission ($status). Inspect $report and $report.log.json." >&2; return 1;
  }
}

staple_and_validate() {
  local artifact="$1" attempt
  for attempt in 1 2 3; do
    if xcrun stapler staple "$artifact" && xcrun stapler validate "$artifact"; then return; fi
    [[ "$attempt" == 3 ]] || sleep 5
  done
  echo "Apple's ticket is not available yet. Rerun notarize to resume." >&2
  return 1
}

case "$MODE" in
  check)
    xcodebuild -version
    xcrun --find notarytool
    xcrun --find stapler
    security find-identity -v -p codesigning
    ;;
  preview)
    mkdir -p "$DIST"
    SALIENT_CODESIGN_IDENTITY=- "$ROOT/script/build_and_run.sh" package
    make_dmg "$DIST/$NAME-$VERSION-development.dmg"
    write_checksum "$DIST/$NAME-$VERSION-development.dmg"
    echo "Development preview: $DIST/$NAME-$VERSION-development.dmg"
    ;;
  prepare)
    require_identity
    "$ROOT/script/build_and_run.sh" package
    verify_signed_app
    prepare_zip
    echo "Prepared without uploading: $ZIP"
    ;;
  notarize)
    require_identity
    [[ -d "$APP" ]] || { echo "Run prepare first." >&2; exit 1; }
    verify_signed_app
    if ! xcrun stapler validate "$APP" >/dev/null 2>&1; then
      prepare_zip
      submit_and_check "$ZIP" "$NOTARY_APP"
      staple_and_validate "$APP"
    fi
    if ! { [[ -f "$DMG" && -f "$DMG.source-cdhash" && -f "$DMG.sha256" ]] &&
        [[ "$(cat "$DMG.source-cdhash")" == "$APP_CDHASH" ]] &&
        (cd "$DIST" && shasum -a 256 -c "$(basename "$DMG").sha256" >/dev/null 2>&1); }; then
      make_dmg "$DMG"
      codesign --force --sign "$IDENTITY" --timestamp "$DMG"
      printf '%s\n' "$APP_CDHASH" > "$DMG.source-cdhash"
      write_checksum "$DMG"
    fi
    codesign --verify --strict "$DMG"
    if ! xcrun stapler validate "$DMG" >/dev/null 2>&1; then
      submit_and_check "$DMG" "$NOTARY_DMG"
      staple_and_validate "$DMG"
    fi
    # Stapling changes the DMG bytes. Preserve this digest even if a later
    # local Gatekeeper check needs to be repeated.
    write_checksum "$DMG"
    spctl --assess --type execute --verbose=2 "$APP"
    spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
    if command -v syspolicy_check >/dev/null 2>&1; then
      syspolicy_check distribution "$APP"
    fi
    echo "Notarized release: $DMG"
    ;;
  help|--help|-h) usage ;;
  *) usage >&2; exit 2 ;;
esac
