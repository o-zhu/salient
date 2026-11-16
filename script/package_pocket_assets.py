#!/usr/bin/env python3
"""Release-time embedding of the pinned Pocket stock assets into an app bundle.

Fetches only the exact immutable HTTPS URLs in pocket-assets.json (no login or
token), caches them under the ignored .build/pocket-assets/<modelRevision>/,
and copies the three verified files plus the receipt and notices into
Contents/Resources/PocketTTS. Python standard library only; nothing here ships
in the app, and the app never writes into its own bundle.

  fetch                  Verify or fill the cache.
  embed RESOURCES        Copy the verified cache into RESOURCES/PocketTTS.
  verify-bundle RESOURCES
                         Check RESOURCES/PocketTTS byte-for-byte.
  scan RESOURCES         Reject private/generated artifacts; the only exception
                         is the exact checksum-verified Pocket bundle.

--source DIR seeds the cache from an explicit folder of existing assets
(DIR/<name> or DIR/assets/<name>) after full size and SHA-256 checks.
"""
from __future__ import annotations

import argparse
import fnmatch
import hashlib
import http.client
import json
import os
import re
import shutil
import ssl
import stat
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST = ROOT / "Sources/SalientCore/Resources/pocket-assets.json"
NOTICES = ROOT / "Sources/SalientCore/Resources/Pocket-Notices.md"
CACHE_ROOT = ROOT / ".build/pocket-assets"

BUNDLE_DIR = "PocketTTS"
VOICE = "alba"
URL_PREFIX = "https://huggingface.co/kyutai/pocket-tts-without-voice-cloning/resolve/"
# Asset name -> path below languages/<model>/ at the pinned revision.
ASSET_PATHS = {
    "model.safetensors": "model.safetensors",
    "tokenizer.json": "tokenizer.json",
    VOICE + ".safetensors": "embeddings/" + VOICE + ".safetensors",
}
MANIFEST_KEYS = {"schema", "pocketVersion", "model", "modelRevision", "voice", "assets"}
ASSET_KEYS = {"name", "url", "bytes", "sha256"}
MAX_ASSET_BYTES = 1 << 30
CHUNK = 1 << 20
FILE_MODE = 0o444
DIR_MODE = 0o755
PARTIAL_MARKER = ".partial-"
USER_AGENT = "Salient-release-packager"
# build_and_run.sh patterns plus common checkpoint formats. Matched case-insensitively.
FORBIDDEN_PATTERNS = (
    "__pycache__", "*.pyc", "*.wav", "*.m4a", "*.mp3", "*.aiff", "*.caf", "*.sqlite*",
    "*.safetensors", "*.gguf", "*.xctest", "*Tests.bundle", "*.pt", "*.pth", "*.ckpt", "*.onnx",
)


class PocketAssetError(Exception):
    pass


def _log(message: str) -> None:
    print("Pocket assets: " + message, file=sys.stderr)


# Manifest -------------------------------------------------------------------

def validate_manifest(data) -> list:
    """Return the asset list if the manifest is the exact pinned stock layout."""
    if not isinstance(data, dict) or set(data) != MANIFEST_KEYS:
        raise PocketAssetError("manifest keys are not the expected schema")
    if data["schema"] != 2 or isinstance(data["schema"], bool):
        raise PocketAssetError("unsupported manifest schema")
    if not isinstance(data["pocketVersion"], str) or not re.fullmatch(r"\d+\.\d+\.\d+", data["pocketVersion"]):
        raise PocketAssetError("invalid pocketVersion")
    model = data["model"]
    if not isinstance(model, str) or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", model):
        raise PocketAssetError("invalid model name")
    revision = data["modelRevision"]
    if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-f]{40}", revision):
        raise PocketAssetError("modelRevision must be a full 40-character commit hash")
    if data["voice"] != VOICE:
        raise PocketAssetError("only the stock " + VOICE + " voice may be bundled")
    assets = data["assets"]
    if not isinstance(assets, list) or len(assets) != len(ASSET_PATHS):
        raise PocketAssetError("manifest must list exactly the stock model, tokenizer and voice")
    names = []
    for asset in assets:
        if not isinstance(asset, dict) or set(asset) != ASSET_KEYS:
            raise PocketAssetError("asset entry keys are not the expected schema")
        name = asset["name"]
        if name not in ASSET_PATHS or name in names:
            raise PocketAssetError("unexpected or duplicate asset name: %r" % (name,))
        names.append(name)
        expected_url = URL_PREFIX + revision + "/languages/" + model + "/" + ASSET_PATHS[name]
        if asset["url"] != expected_url:
            raise PocketAssetError(name + " URL is not the pinned immutable HTTPS location")
        size = asset["bytes"]
        if not isinstance(size, int) or isinstance(size, bool) or not 0 < size <= MAX_ASSET_BYTES:
            raise PocketAssetError(name + " has an invalid size")
        if not isinstance(asset["sha256"], str) or not re.fullmatch(r"[0-9a-f]{64}", asset["sha256"]):
            raise PocketAssetError(name + " has an invalid SHA-256")
    return assets


def load_manifest(path: Path):
    """Return (exact manifest bytes, parsed manifest, assets)."""
    raw = read_regular(path)
    try:
        data = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as error:
        raise PocketAssetError("manifest is not valid JSON: %s" % error)
    return raw, data, validate_manifest(data)


# Files ----------------------------------------------------------------------

def _open_regular(path: Path) -> int:
    """Open without following a final symlink; raise unless it is a regular file."""
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0))
    except FileNotFoundError:
        raise
    except OSError as error:
        raise PocketAssetError("refusing %s: %s" % (path, error.strerror or error))
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise PocketAssetError("refusing non-regular file " + str(path))
    return fd


def read_regular(path: Path) -> bytes:
    try:
        fd = _open_regular(path)
    except FileNotFoundError:
        raise PocketAssetError("missing " + str(path))
    with os.fdopen(fd, "rb") as handle:
        return handle.read()


def _iter_fd(fd: int):
    with os.fdopen(fd, "rb") as handle:
        while True:
            chunk = handle.read(CHUNK)
            if not chunk:
                return
            yield chunk


def file_matches(path: Path, asset) -> bool:
    """True only for a regular non-symlink file of the exact size and SHA-256."""
    try:
        fd = _open_regular(path)
    except FileNotFoundError:
        return False
    if os.fstat(fd).st_size != asset["bytes"]:
        os.close(fd)
        return False
    digest = hashlib.sha256()
    for chunk in _iter_fd(fd):
        digest.update(chunk)
    return digest.hexdigest() == asset["sha256"]


def _require_dir(path: Path, create: bool = False) -> None:
    """Require a real directory (not a symlink), optionally creating it."""
    try:
        info = os.lstat(str(path))
    except FileNotFoundError:
        if not create:
            raise PocketAssetError("missing directory " + str(path))
        os.mkdir(str(path), DIR_MODE)
        info = os.lstat(str(path))
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise PocketAssetError("refusing non-directory or symlink " + str(path))


def _write_verified_temp(directory: Path, asset, chunks) -> Path:
    """Write chunks to a private temporary file in directory and verify it.

    The temporary name is never a valid asset name, so an interrupted run can
    never leave a partial file that later passes as complete.
    """
    fd, temp = tempfile.mkstemp(prefix="." + asset["name"] + PARTIAL_MARKER, dir=str(directory))
    try:
        digest = hashlib.sha256()
        written = 0
        with os.fdopen(fd, "wb") as handle:
            for chunk in chunks:
                written += len(chunk)
                if written > asset["bytes"]:
                    raise PocketAssetError(asset["name"] + " is larger than the manifest size")
                digest.update(chunk)
                handle.write(chunk)
            handle.flush()
            os.fsync(handle.fileno())
        if written != asset["bytes"] or digest.hexdigest() != asset["sha256"]:
            raise PocketAssetError(asset["name"] + " does not match the manifest size and SHA-256")
        os.chmod(temp, 0o644)
        return Path(temp)
    except BaseException:
        try:
            os.unlink(temp)
        except FileNotFoundError:
            pass
        raise


def _write_new_file(path: Path, data: bytes) -> None:
    fd = os.open(str(path), os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "wb") as handle:
        handle.write(data)
        handle.flush()
        os.fsync(handle.fileno())
    os.chmod(str(path), FILE_MODE)


# Download -------------------------------------------------------------------

class _HTTPSOnlyRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise urllib.error.HTTPError(newurl, code, "refusing non-HTTPS redirect", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def _default_opener():
    opener = urllib.request.build_opener(
        _HTTPSOnlyRedirect, urllib.request.HTTPSHandler(context=ssl.create_default_context()))
    return lambda request: opener.open(request, timeout=60)


def _iter_response(response):
    while True:
        chunk = response.read(CHUNK)
        if not chunk:
            return
        yield chunk


def _download(asset, cache_dir: Path, opener) -> Path:
    request = urllib.request.Request(asset["url"], headers={"User-Agent": USER_AGENT})
    try:
        with opener(request) as response:
            status = getattr(response, "status", None) or response.getcode()
            if status != 200:
                raise PocketAssetError("%s download returned HTTP %s" % (asset["name"], status))
            final_url = response.geturl() if hasattr(response, "geturl") else asset["url"]
            if urllib.parse.urlsplit(final_url).scheme != "https":
                raise PocketAssetError(asset["name"] + " download left HTTPS")
            length = response.headers.get("Content-Length") if getattr(response, "headers", None) else None
            if length is not None and length.strip().isdigit() and int(length) != asset["bytes"]:
                raise PocketAssetError(asset["name"] + " server size does not match the manifest")
            return _write_verified_temp(cache_dir, asset, _iter_response(response))
    except (urllib.error.URLError, http.client.HTTPException, OSError) as error:
        raise PocketAssetError("%s download failed: %s" % (asset["name"], error))


# Cache ----------------------------------------------------------------------

def _seed_from_source(asset, source: Path, cache_dir: Path) -> Path:
    candidates = [source / asset["name"]]
    nested = source / "assets"
    if os.path.lexists(str(nested)):
        _require_dir(nested)
        candidates.append(nested / asset["name"])
    for candidate in candidates:
        try:
            fd = _open_regular(candidate)
        except FileNotFoundError:
            continue
        try:
            return _write_verified_temp(cache_dir, asset, _iter_fd(fd))
        except PocketAssetError:
            raise PocketAssetError(str(candidate) + " does not match the manifest size and SHA-256")
    raise PocketAssetError(asset["name"] + " was not found in " + str(source))


def ensure_cache(manifest, assets, cache_root: Path, source: Path = None,
                 offline: bool = False, opener=None) -> Path:
    """Return .../<modelRevision>/ holding exactly-verified copies of every asset."""
    cache_root.parent.mkdir(parents=True, exist_ok=True)
    _require_dir(cache_root, create=True)
    cache_dir = cache_root / manifest["modelRevision"]
    _require_dir(cache_dir, create=True)
    if source is not None:
        _require_dir(source)
    for entry in list(os.scandir(str(cache_dir))):
        if entry.name.startswith(".") and PARTIAL_MARKER in entry.name and entry.is_file(follow_symlinks=False):
            os.unlink(entry.path)
    for asset in assets:
        target = cache_dir / asset["name"]
        if os.path.lexists(str(target)):
            info = os.lstat(str(target))
            if not stat.S_ISREG(info.st_mode):
                raise PocketAssetError("refusing non-regular cache entry " + str(target))
            if file_matches(target, asset):
                continue
            _log("discarding stale cached " + asset["name"])
            os.unlink(str(target))
        if source is not None:
            _log("seeding %s from %s" % (asset["name"], source))
            temp = _seed_from_source(asset, source, cache_dir)
        elif offline:
            raise PocketAssetError(asset["name"] + " is not cached; run without --offline or pass --source")
        else:
            _log("downloading %s (%.1f MB)" % (asset["name"], asset["bytes"] / 1e6))
            temp = _download(asset, cache_dir, opener or _default_opener())
        os.replace(str(temp), str(target))
    return cache_dir


# Bundle ---------------------------------------------------------------------

def _verify_tree(pocket: Path, raw_manifest: bytes, notices: bytes, assets) -> None:
    _require_dir(pocket)
    if sorted(os.listdir(str(pocket))) != sorted(["NOTICES.md", "assets", "receipt.json"]):
        raise PocketAssetError(str(pocket) + " must contain exactly receipt.json, NOTICES.md and assets/")
    asset_dir = pocket / "assets"
    _require_dir(asset_dir)
    if sorted(os.listdir(str(asset_dir))) != sorted(a["name"] for a in assets):
        raise PocketAssetError(str(asset_dir) + " must contain exactly the manifest assets")
    for directory in (pocket, asset_dir):
        if os.lstat(str(directory)).st_mode & 0o555 != 0o555:
            raise PocketAssetError(str(directory) + " is not world-readable")
    files = [pocket / "receipt.json", pocket / "NOTICES.md"] + [asset_dir / a["name"] for a in assets]
    for path in files:
        mode = os.lstat(str(path)).st_mode
        if stat.S_ISLNK(mode) or not stat.S_ISREG(mode) or mode & 0o777 != FILE_MODE:
            raise PocketAssetError(str(path) + " must be a read-only regular file")
    if read_regular(pocket / "receipt.json") != raw_manifest:
        raise PocketAssetError("receipt.json is not the exact bundled pocket-assets.json")
    if read_regular(pocket / "NOTICES.md") != notices:
        raise PocketAssetError("NOTICES.md is not the exact Pocket-Notices.md")
    for asset in assets:
        if not file_matches(asset_dir / asset["name"], asset):
            raise PocketAssetError(asset["name"] + " in the bundle does not match the manifest")


def verify_bundle(resources: Path, manifest_path: Path = MANIFEST, notices_path: Path = NOTICES) -> None:
    raw, _, assets = load_manifest(manifest_path)
    _verify_tree(resources / BUNDLE_DIR, raw, read_regular(notices_path), assets)


def embed(resources: Path, manifest_path: Path = MANIFEST, notices_path: Path = NOTICES,
          cache_root: Path = CACHE_ROOT, source: Path = None, offline: bool = False, opener=None) -> Path:
    raw, manifest, assets = load_manifest(manifest_path)
    notices = read_regular(notices_path)
    if not notices.strip():
        raise PocketAssetError("Pocket notices are empty")
    _require_dir(resources)
    destination = resources / BUNDLE_DIR
    if os.path.lexists(str(destination)):
        raise PocketAssetError(str(destination) + " already exists; package from a clean bundle")
    cache_dir = ensure_cache(manifest, assets, cache_root, source=source, offline=offline, opener=opener)
    staging = Path(tempfile.mkdtemp(prefix="." + BUNDLE_DIR + ".staging-", dir=str(resources)))
    try:
        asset_dir = staging / "assets"
        os.mkdir(str(asset_dir), DIR_MODE)
        _write_new_file(staging / "receipt.json", raw)
        _write_new_file(staging / "NOTICES.md", notices)
        for asset in assets:
            try:
                fd = _open_regular(cache_dir / asset["name"])
            except FileNotFoundError:
                raise PocketAssetError("cache lost " + asset["name"])
            temp = _write_verified_temp(asset_dir, asset, _iter_fd(fd))
            os.chmod(str(temp), FILE_MODE)
            os.rename(str(temp), str(asset_dir / asset["name"]))
        os.chmod(str(asset_dir), DIR_MODE)
        os.chmod(str(staging), DIR_MODE)
        _verify_tree(staging, raw, notices, assets)
        os.rename(str(staging), str(destination))
    except BaseException:
        shutil.rmtree(str(staging), ignore_errors=True)
        raise
    return destination


def _forbidden(name: str) -> bool:
    lowered = name.lower()
    return any(fnmatch.fnmatchcase(lowered, pattern.lower()) for pattern in FORBIDDEN_PATTERNS)


def scan_resources(resources: Path, manifest_path: Path = MANIFEST, notices_path: Path = NOTICES,
                   require_pocket: bool = False) -> list:
    """Return forbidden relative paths under resources (empty means clean).

    The only exception is the exact manifest asset paths in PocketTTS/assets,
    and only after the whole PocketTTS tree passes full checksum validation.
    """
    _require_dir(resources)
    approved = set()
    if os.path.lexists(str(resources / BUNDLE_DIR)):
        raw, _, assets = load_manifest(manifest_path)
        _verify_tree(resources / BUNDLE_DIR, raw, read_regular(notices_path), assets)
        approved = {BUNDLE_DIR + "/assets/" + a["name"] for a in assets}
    elif require_pocket:
        raise PocketAssetError("missing " + str(resources / BUNDLE_DIR))

    def fail(error):
        raise error

    found = []
    for directory, dirnames, filenames in os.walk(str(resources), onerror=fail, followlinks=False):
        relative = os.path.relpath(directory, str(resources))
        for name in sorted(dirnames + filenames):
            path = name if relative == "." else relative + "/" + name
            if _forbidden(name) and path not in approved:
                found.append(path)
    return found


# CLI ------------------------------------------------------------------------

def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("fetch", "embed"):
        command = commands.add_parser(name)
        if name == "embed":
            command.add_argument("resources", type=Path)
        command.add_argument("--source", type=Path, help="explicit folder of existing assets to seed the cache")
        command.add_argument("--offline", action="store_true", help="use only the cache or --source")
    commands.add_parser("verify-bundle").add_argument("resources", type=Path)
    scan = commands.add_parser("scan")
    scan.add_argument("resources", type=Path)
    scan.add_argument("--require-pocket", action="store_true")
    args = parser.parse_args(argv)

    source = getattr(args, "source", None)
    if source is not None:
        source = Path(os.path.abspath(os.path.expanduser(str(source))))
    try:
        if args.command == "fetch":
            _, manifest, assets = load_manifest(MANIFEST)
            cache = ensure_cache(manifest, assets, CACHE_ROOT, source=source, offline=args.offline)
            _log("verified cache " + str(cache))
        elif args.command == "embed":
            _log("embedded " + str(embed(args.resources, source=source, offline=args.offline)))
        elif args.command == "verify-bundle":
            verify_bundle(args.resources)
            _log("verified " + str(args.resources / BUNDLE_DIR))
        else:
            found = scan_resources(args.resources, require_pocket=args.require_pocket)
            if found:
                print("Refusing to package generated or private resource artifacts:", file=sys.stderr)
                for path in found:
                    print("  " + str(args.resources / path), file=sys.stderr)
                return 1
    except PocketAssetError as error:
        _log(str(error))
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
