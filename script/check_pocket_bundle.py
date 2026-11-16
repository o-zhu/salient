#!/usr/bin/env python3
"""Exercise a packaged app's normal Pocket lookup with a fresh, offline home.

Synthesis is silent by default. Wrap --playback in tools/codex-tts/tts-capture.sh.
Reports and the isolated user home must stay in ignored build/capture folders.
"""
import argparse
import json
import os
from pathlib import Path
import plistlib
import subprocess
import sys
import tempfile


def run(app: Path, out: Path, playback: bool) -> dict:
    app = app.resolve(strict=True)
    if app.suffix != ".app":
        raise ValueError("Pass a packaged .app, not a bare Swift executable")
    out.mkdir(parents=True, exist_ok=True)
    out = out.resolve()
    fresh = Path(tempfile.mkdtemp(prefix="offline-home-", dir=out))
    # Foundation honors CFFIXED_USER_HOME without changing the real HOME or
    # moving the owner's preferences/models out of the way.
    environment = dict(os.environ, CFFIXED_USER_HOME=str(fresh))
    # Match the worker's own sandbox: macOS rejects its nested sandbox_apply
    # when this outer profile adds file restrictions that the inner one omits.
    # Isolate assets through the empty Foundation home and assert the resolved
    # source below. A separate run from a read-only DMG verifies read-only use.
    profile = "(version 1) (allow default) (deny network*)"
    sandbox = ["/usr/bin/sandbox-exec", "-p", profile]
    network_check = """import errno,socket,sys
try:
    with socket.socket(socket.AF_INET,socket.SOCK_STREAM) as sock:
        sock.settimeout(1)
        sock.connect(('127.0.0.1',9))
except OSError as e:
    sys.exit(0 if e.errno in (errno.EPERM,errno.EACCES) else 2)
sys.exit(3)
"""
    subprocess.run(sandbox + [sys.executable, "-c", network_check], env=environment, check=True, timeout=10)
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    name = info["CFBundleExecutable"]
    if Path(name).name != name:
        raise ValueError("Invalid bundle executable")
    command = sandbox + [str(app / "Contents/MacOS" / name), "--pocket-bundle-check"]
    if playback:
        command.append("--play-pocket-bundle-check")
    result = subprocess.run(command, env=environment, capture_output=True, text=True, timeout=120)
    (out / "app.stdout.log").write_text(result.stdout)
    (out / "app.stderr.log").write_text(result.stderr)
    if result.returncode:
        raise RuntimeError(f"Packaged app check failed ({result.returncode}); inspect {out / 'app.stderr.log'}")
    report = json.loads(result.stdout)
    expected_managed = fresh / "Library/Application Support/Salient/PocketTTS/native-v2"
    expected_bundle = app / "Contents/Resources/PocketTTS"
    assert report["status"] == "passed" and report["source"] == "bundled", report
    assert Path(report["managedRoot"]) == expected_managed, "The app did not use the isolated user home"
    assert Path(report["bundledRoot"]) == expected_bundle, "The app did not use its own bundled assets"
    assert not expected_managed.exists(), "The app copied assets into Application Support"
    assert not list(fresh.rglob("*.safetensors")), "Unexpected model copy in the fresh home"
    assert report["playbackCompleted"] == playback
    # Check the signed resources again after synthesis.
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
    report.update({"app": str(app), "freshHome": str(fresh), "networkDenied": True,
                   "networkDenialProbePassed": True, "bundledSourceVerified": True,
                   "appVolumeReadOnly": bool(os.statvfs(app).f_flag & os.ST_RDONLY),
                   "signatureVerifiedAfter": True})
    (out / "verification.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--playback", action="store_true")
    args = parser.parse_args()
    print(json.dumps(run(args.app, args.out, args.playback), indent=2))
