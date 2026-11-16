#!/usr/bin/env python3
"""Offline tests for script/package_pocket_assets.py using synthetic assets only."""
import copy
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import unittest
from unittest import mock

TOOL_PATH = Path(__file__).resolve().parent.parent / "package_pocket_assets.py"
SPEC = importlib.util.spec_from_file_location("package_pocket_assets", str(TOOL_PATH))
tool = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(tool)
PocketAssetError = tool.PocketAssetError

REVISION = "0123456789abcdef0123456789abcdef01234567"
MODEL = "english_test"
BODIES = {
    "model.safetensors": b"synthetic model bytes\x00" * 4096,
    "tokenizer.json": b'{"synthetic": true}\n',
    "alba.safetensors": b"synthetic voice" * 300,
}
NOTICES = b"# Synthetic notices\n\nCC BY 4.0 attribution text.\n"


def sha(data):
    return hashlib.sha256(data).hexdigest()


def url_for(name, revision=REVISION, model=MODEL):
    return tool.URL_PREFIX + revision + "/languages/" + model + "/" + tool.ASSET_PATHS[name]


def make_manifest():
    return {
        "schema": 2, "pocketVersion": "4.0.1", "model": MODEL, "modelRevision": REVISION, "voice": "alba",
        "assets": [{"name": name, "url": url_for(name), "bytes": len(body), "sha256": sha(body)}
                   for name, body in BODIES.items()],
    }


class FakeResponse(io.BytesIO):
    def __init__(self, body, status=200, url=None, length=None):
        super().__init__(body)
        self.status = status
        self._url = url
        self.headers = {} if length is None else {"Content-Length": str(length)}

    def geturl(self):
        return self._url


class FakeOpener:
    """Serves synthetic bodies for manifest URLs; never touches the network."""

    def __init__(self, bodies=None, status=200, final_url=None):
        self.bodies = {url_for(name): body for name, body in (bodies or BODIES).items()}
        self.status = status
        self.final_url = final_url
        self.calls = []

    def __call__(self, request):
        self.calls.append(request.full_url)
        if "Authorization" in request.headers:
            raise AssertionError("no credentials may be sent")
        return FakeResponse(self.bodies[request.full_url], self.status, self.final_url or request.full_url)


def refuse_network(request):
    raise AssertionError("unexpected download of " + request.full_url)


def make_writable(path):
    os.chmod(str(path), 0o644)


class Fixture(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.manifest = make_manifest()
        self.manifest_path = self.tmp / "pocket-assets.json"
        self.manifest_bytes = (json.dumps(self.manifest, indent=2) + "\n").encode()
        self.manifest_path.write_bytes(self.manifest_bytes)
        self.notices_path = self.tmp / "Pocket-Notices.md"
        self.notices_path.write_bytes(NOTICES)
        (self.tmp / ".build").mkdir()
        self.cache_root = self.tmp / ".build/pocket-assets"
        self.cache_dir = self.cache_root / REVISION
        self.resources = self.tmp / "Salient.app/Contents/Resources"
        self.resources.mkdir(parents=True)

    def tearDown(self):
        shutil.rmtree(str(self.tmp), ignore_errors=True)

    def ensure(self, opener=None, **kwargs):
        return tool.ensure_cache(self.manifest, self.manifest["assets"], self.cache_root,
                                 opener=opener or FakeOpener(), **kwargs)

    def embed(self, opener=None, **kwargs):
        return tool.embed(self.resources, self.manifest_path, self.notices_path, self.cache_root,
                          opener=opener or FakeOpener(), **kwargs)

    def verify(self):
        tool.verify_bundle(self.resources, self.manifest_path, self.notices_path)

    def scan(self, **kwargs):
        return tool.scan_resources(self.resources, self.manifest_path, self.notices_path, **kwargs)

    def assert_no_partials(self, directory):
        if directory.exists():
            leftovers = [name for name in os.listdir(str(directory)) if tool.PARTIAL_MARKER in name]
            self.assertEqual(leftovers, [])


class ManifestTests(unittest.TestCase):
    def test_repository_manifest_is_the_pinned_stock_layout(self):
        _, data, assets = tool.load_manifest(tool.MANIFEST)
        self.assertEqual(data["voice"], "alba")
        self.assertEqual(sorted(a["name"] for a in assets), sorted(tool.ASSET_PATHS))

    def test_synthetic_manifest_is_valid(self):
        self.assertEqual(len(tool.validate_manifest(make_manifest())), 3)

    def test_rejects_untrusted_or_ambiguous_manifests(self):
        def asset(manifest, name):
            return next(a for a in manifest["assets"] if a["name"] == name)

        mutations = {
            "http": lambda m: asset(m, "model.safetensors").update(url=url_for("model.safetensors").replace("https:", "http:")),
            "other host": lambda m: asset(m, "model.safetensors").update(
                url=url_for("model.safetensors").replace("huggingface.co", "example.com")),
            "query": lambda m: asset(m, "tokenizer.json").update(url=url_for("tokenizer.json") + "?download=1"),
            "mutable branch": lambda m: asset(m, "alba.safetensors").update(
                url=url_for("alba.safetensors").replace(REVISION, "main")),
            "url for another asset": lambda m: asset(m, "alba.safetensors").update(url=url_for("model.safetensors")),
            "unknown name": lambda m: asset(m, "alba.safetensors").update(name="custom.safetensors"),
            "duplicate": lambda m: m["assets"].__setitem__(2, copy.deepcopy(m["assets"][0])),
            "extra asset": lambda m: m["assets"].append(copy.deepcopy(m["assets"][0])),
            "missing asset": lambda m: m["assets"].pop(),
            "traversal revision": lambda m: m.update(modelRevision="../../../../tmp/x"),
            "short revision": lambda m: m.update(modelRevision="a7056f5"),
            "other voice": lambda m: m.update(voice="crisp"),
            "bad model": lambda m: m.update(model="../english"),
            "zero bytes": lambda m: asset(m, "tokenizer.json").update(bytes=0),
            "bool bytes": lambda m: asset(m, "tokenizer.json").update(bytes=True),
            "huge": lambda m: asset(m, "model.safetensors").update(bytes=tool.MAX_ASSET_BYTES + 1),
            "uppercase sha": lambda m: asset(m, "tokenizer.json").update(sha256="A" * 64),
            "short sha": lambda m: asset(m, "tokenizer.json").update(sha256="a" * 63),
            "extra key": lambda m: m.update(token="hf_secret"),
            "asset extra key": lambda m: asset(m, "tokenizer.json").update(headers={"Authorization": "x"}),
            "schema": lambda m: m.update(schema=1),
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                manifest = make_manifest()
                mutate(manifest)
                with self.assertRaises(PocketAssetError):
                    tool.validate_manifest(manifest)


class CacheTests(Fixture):
    def test_downloads_verified_files_then_reuses_cache_without_network(self):
        opener = FakeOpener()
        cache = self.ensure(opener)
        self.assertEqual(cache, self.cache_dir)
        self.assertEqual(sorted(opener.calls), sorted(url_for(name) for name in BODIES))
        for name, body in BODIES.items():
            self.assertEqual((cache / name).read_bytes(), body)
        self.ensure(refuse_network)
        self.assertEqual(sorted(os.listdir(str(cache))), sorted(BODIES))

    def test_checksum_mismatch_leaves_no_valid_or_partial_file(self):
        tampered = dict(BODIES)
        body = bytearray(BODIES["model.safetensors"])
        body[-1] ^= 1
        tampered["model.safetensors"] = bytes(body)
        with self.assertRaises(PocketAssetError):
            self.ensure(FakeOpener(tampered))
        self.assertFalse((self.cache_dir / "model.safetensors").exists())
        self.assert_no_partials(self.cache_dir)

    def test_oversized_and_truncated_downloads_are_rejected(self):
        for label, body in (("oversized", BODIES["alba.safetensors"] + b"x"),
                            ("truncated", BODIES["alba.safetensors"][:-1])):
            with self.subTest(label):
                bodies = dict(BODIES, **{"alba.safetensors": body})
                with self.assertRaises(PocketAssetError):
                    self.ensure(FakeOpener(bodies))
                self.assertFalse((self.cache_dir / "alba.safetensors").exists())
                self.assert_no_partials(self.cache_dir)

    def test_http_error_status_and_https_downgrade_are_rejected(self):
        with self.assertRaises(PocketAssetError):
            self.ensure(FakeOpener(status=500))
        with self.assertRaises(PocketAssetError):
            self.ensure(FakeOpener(final_url="http://cdn.example.com/model.safetensors"))
        self.assert_no_partials(self.cache_dir)

    def test_redirect_handler_refuses_non_https(self):
        handler = tool._HTTPSOnlyRedirect()
        request = tool.urllib.request.Request(url_for("model.safetensors"))
        with self.assertRaises(tool.urllib.error.HTTPError):
            handler.redirect_request(request, None, 302, "Found", {}, "http://cdn.example.com/x")
        with self.assertRaises(tool.urllib.error.HTTPError):
            handler.redirect_request(request, None, 302, "Found", {}, "file:///etc/passwd")

    def test_stale_cache_entry_and_partials_are_replaced(self):
        self.ensure()
        model = self.cache_dir / "model.safetensors"
        model.write_bytes(b"\x00" * len(BODIES["model.safetensors"]))
        partial = self.cache_dir / (".model.safetensors" + tool.PARTIAL_MARKER + "abc")
        partial.write_bytes(b"partial")
        opener = FakeOpener()
        self.ensure(opener)
        self.assertEqual(opener.calls, [url_for("model.safetensors")])
        self.assertEqual(model.read_bytes(), BODIES["model.safetensors"])
        self.assertFalse(partial.exists())

    def test_symlinked_cache_entries_and_roots_are_refused(self):
        outside = self.tmp / "outside.safetensors"
        outside.write_bytes(BODIES["model.safetensors"])
        self.cache_dir.mkdir(parents=True)
        os.symlink(str(outside), str(self.cache_dir / "model.safetensors"))
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network)

        shutil.rmtree(str(self.cache_root))
        elsewhere = self.tmp / "elsewhere"
        elsewhere.mkdir()
        os.symlink(str(elsewhere), str(self.cache_root))
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network)
        self.assertEqual(os.listdir(str(elsewhere)), [])

    def test_offline_without_cache_fails_without_network(self):
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network, offline=True)

    def test_seeds_from_explicit_flat_or_nested_source_without_network(self):
        for layout in ("flat", "nested"):
            with self.subTest(layout):
                shutil.rmtree(str(self.cache_root), ignore_errors=True)
                source = self.tmp / ("source-" + layout)
                folder = source / "assets" if layout == "nested" else source
                folder.mkdir(parents=True)
                for name, body in BODIES.items():
                    (folder / name).write_bytes(body)
                self.ensure(refuse_network, source=source)
                for name, body in BODIES.items():
                    self.assertEqual((self.cache_dir / name).read_bytes(), body)

    def test_source_seeding_rejects_mismatch_symlink_and_missing_files(self):
        source = self.tmp / "source"
        source.mkdir()
        for name, body in BODIES.items():
            (source / name).write_bytes(body)
        (source / "tokenizer.json").write_bytes(b"x" * len(BODIES["tokenizer.json"]))
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network, source=source)
        self.assertFalse((self.cache_dir / "tokenizer.json").exists())
        self.assert_no_partials(self.cache_dir)

        (source / "tokenizer.json").unlink()
        real = self.tmp / "real-tokenizer.json"
        real.write_bytes(BODIES["tokenizer.json"])
        os.symlink(str(real), str(source / "tokenizer.json"))
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network, source=source)

        (source / "tokenizer.json").unlink()
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network, source=source)

        linked_source = self.tmp / "linked-source"
        os.symlink(str(source), str(linked_source))
        with self.assertRaises(PocketAssetError):
            self.ensure(refuse_network, source=linked_source)


class BundleTests(Fixture):
    def test_embed_creates_exact_read_only_tree(self):
        destination = self.embed()
        self.assertEqual(destination, self.resources / "PocketTTS")
        self.assertEqual(sorted(os.listdir(str(destination))), ["NOTICES.md", "assets", "receipt.json"])
        self.assertEqual(sorted(os.listdir(str(destination / "assets"))), sorted(BODIES))
        self.assertEqual((destination / "receipt.json").read_bytes(), self.manifest_bytes)
        self.assertEqual((destination / "NOTICES.md").read_bytes(), NOTICES)
        for name, body in BODIES.items():
            path = destination / "assets" / name
            self.assertEqual(path.read_bytes(), body)
            self.assertEqual(stat.S_IMODE(os.lstat(str(path)).st_mode), 0o444)
        self.assertEqual(os.listdir(str(self.resources)), ["PocketTTS"])
        self.verify()

    def test_embed_refuses_existing_destination(self):
        (self.resources / "PocketTTS").mkdir()
        with self.assertRaises(PocketAssetError):
            self.embed()

    def test_failed_embed_removes_staging(self):
        with mock.patch.object(tool, "_verify_tree", side_effect=PocketAssetError("synthetic")):
            with self.assertRaises(PocketAssetError):
                self.embed()
        self.assertEqual(os.listdir(str(self.resources)), [])

    def test_embed_offline_uses_only_cache(self):
        self.ensure()
        self.embed(refuse_network, offline=True)
        self.verify()

    def test_verify_rejects_any_deviation(self):
        def flip_byte(pocket):
            path = pocket / "assets/model.safetensors"
            make_writable(path)
            data = bytearray(path.read_bytes())
            data[10] ^= 1
            path.write_bytes(bytes(data))
            os.chmod(str(path), 0o444)

        def reformat_receipt(pocket):
            path = pocket / "receipt.json"
            make_writable(path)
            path.write_bytes(json.dumps(json.loads(path.read_bytes())).encode())
            os.chmod(str(path), 0o444)

        def edit_notices(pocket):
            path = pocket / "NOTICES.md"
            make_writable(path)
            path.write_bytes(NOTICES + b"extra\n")
            os.chmod(str(path), 0o444)

        def symlink_asset(pocket):
            path = pocket / "assets/alba.safetensors"
            path.unlink()
            os.symlink(str(self.cache_dir / "alba.safetensors"), str(path))

        mutations = {
            "extra top-level file": lambda p: (p / "voice.wav").write_bytes(b"x"),
            "DS_Store": lambda p: (p / "assets/.DS_Store").write_bytes(b"x"),
            "extra weights": lambda p: (p / "assets/custom.safetensors").write_bytes(b"x"),
            "missing asset": lambda p: (p / "assets/tokenizer.json").unlink(),
            "writable asset": lambda p: make_writable(p / "assets/tokenizer.json"),
            "flipped byte": flip_byte,
            "reformatted receipt": reformat_receipt,
            "edited notices": edit_notices,
            "symlinked asset": symlink_asset,
        }
        for label, mutate in mutations.items():
            with self.subTest(label):
                shutil.rmtree(str(self.resources / "PocketTTS"), ignore_errors=True)
                self.embed()
                mutate(self.resources / "PocketTTS")
                with self.assertRaises(PocketAssetError):
                    self.verify()
                with self.assertRaises(PocketAssetError):
                    self.scan(require_pocket=True)


class ScanTests(Fixture):
    def test_accepts_verified_bundle_and_ordinary_resources(self):
        self.embed()
        core = self.resources / "Salient_SalientCore.bundle/Contents/Resources"
        core.mkdir(parents=True)
        (core / "two-pane.html").write_text("<html></html>")
        self.assertEqual(self.scan(require_pocket=True), [])

    def test_requires_pocket_when_asked(self):
        with self.assertRaises(PocketAssetError):
            self.scan(require_pocket=True)
        self.assertEqual(self.scan(), [])

    def test_rejects_private_artifacts_and_weights_outside_exact_paths(self):
        self.embed()
        core = self.resources / "Salient_SalientCore.bundle/Contents/Resources"
        (core / "__pycache__").mkdir(parents=True)
        (core / "model.safetensors").write_bytes(BODIES["model.safetensors"])
        (core / "Crisp.WAV").write_bytes(b"x")
        (core / "Model.GGUF").write_bytes(b"x")
        (core / "checkpoint.pt").write_bytes(b"x")
        (core / "store.sqlite-wal").write_bytes(b"x")
        nested = self.resources / "Other/PocketTTS/assets"
        nested.mkdir(parents=True)
        (nested / "alba.safetensors").write_bytes(BODIES["alba.safetensors"])
        os.symlink(str(self.resources / "PocketTTS/assets/model.safetensors"), str(self.resources / "link.safetensors"))
        found = self.scan(require_pocket=True)
        prefix = "Salient_SalientCore.bundle/Contents/Resources/"
        self.assertEqual(sorted(found), sorted([
            prefix + "__pycache__", prefix + "model.safetensors", prefix + "Crisp.WAV",
            prefix + "Model.GGUF", prefix + "checkpoint.pt", prefix + "store.sqlite-wal",
            "Other/PocketTTS/assets/alba.safetensors", "link.safetensors",
        ]))

    def test_unverified_pocket_directory_gets_no_exception(self):
        pocket = self.resources / "PocketTTS/assets"
        pocket.mkdir(parents=True)
        (pocket / "model.safetensors").write_bytes(BODIES["model.safetensors"])
        with self.assertRaises(PocketAssetError):
            self.scan()

    def test_cli_scan_reports_forbidden_files(self):
        clean = self.tmp / "clean"
        clean.mkdir()
        self.assertEqual(tool.main(["scan", str(clean)]), 0)
        self.assertEqual(tool.main(["scan", str(clean), "--require-pocket"]), 1)
        (clean / "weights.safetensors").write_bytes(b"x")
        with mock.patch.object(sys, "stderr", io.StringIO()):
            self.assertEqual(tool.main(["scan", str(clean)]), 1)


if __name__ == "__main__":
    unittest.main()
