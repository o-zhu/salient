"""Publication checks use invented fixtures only; never real credentials."""
import importlib.util
from pathlib import Path
import unittest


spec = importlib.util.spec_from_file_location("public_source", Path(__file__).parents[1] / "check_public_source.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class PublicSourceTests(unittest.TestCase):
    def test_source_and_synthetic_redaction_path_are_allowed(self):
        self.assertEqual(module.violations("Sources/Example.swift", b'let path = "/Users/example/private.wav"'), [])

    def test_force_added_private_files_are_rejected(self):
        for path in ["imports/page.md", "clip.wav", "model.safetensors", "dist/App.app/file", ".env", "data/notes.txt", "test.sqlite-wal"]:
            with self.subTest(path=path):
                self.assertTrue(module.violations(path, b"test"))

    def test_secrets_and_personal_home_paths_are_rejected_without_echoing_them(self):
        fixtures = [b"ghp_" + b"a" * 36, b"hf_" + b"b" * 24,
                    b"-----BEGIN " + b"PRIVATE KEY-----", b"/Users/" + b"fixture-person/private/file"]
        for content in fixtures:
            with self.subTest(length=len(content)):
                reasons = module.violations("config.txt", content)
                self.assertTrue(reasons)
                self.assertTrue(all(content.decode() not in reason for reason in reasons))

    def test_lfs_does_not_allow_model_assets_into_source_history(self):
        pointer = b"version " + b"https://git-lfs.github.com/spec/v1\noid sha256:example"
        self.assertIn("Git LFS pointer", module.violations("weights.txt", pointer))

    def test_binary_and_external_symlink_are_rejected(self):
        self.assertTrue(module.violations("Sources/payload", b"\x00\xff"))
        self.assertTrue(module.violations("Sources/link.swift", b"../other/file.swift", "120000"))

    def test_private_application_sources_cannot_be_force_added(self):
        for path in ["Sources/SalientLauncher/main.swift",
                     "Sources/SalientCore/Features/StudyLibrary/Store.swift",
                     "Sources/SalientCore/Services/AI/Runtime.swift",
                     "Sources/Salient/App/PodcastTranscriptsView.swift"]:
            with self.subTest(path=path):
                self.assertTrue(module.violations(path, b"// source"))

    def test_private_implementation_cannot_be_hidden_in_reader_source(self):
        self.assertTrue(module.violations("Sources/Salient/App/AppModel.swift",
                                         b"let runtime: LocalTextModelRuntimeManager"))
        self.assertEqual(module.violations("Sources/Salient/App/AppModel.swift",
                                          b"let runtime: PocketRuntimeManager"), [])


if __name__ == "__main__":
    unittest.main()
