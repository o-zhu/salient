"""Exercise notarization recovery without any Apple account or network calls."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


RELEASE = Path(__file__).resolve().parents[1] / "release.sh"
FAKE_NOTARY = r'''
import json, os, pathlib, sys
state_path = pathlib.Path(os.environ["FAKE_NOTARY_STATE"])
state = json.loads(state_path.read_text()) if state_path.exists() else {"calls": [], "submissions": 0}
command = sys.argv[2]
state["calls"].append(command)
if command == "submit":
    state["submissions"] += 1
state_path.write_text(json.dumps(state))
submission = "synthetic-" + str(state["submissions"])
if command == "submit":
    print(json.dumps({"id": submission, "status": "In Progress"}))
elif command == "info":
    print(json.dumps({"id": sys.argv[3], "status": "In Progress"}))
elif command == "wait":
    if os.environ.get("FAKE_WAIT_FAIL") == "1":
        sys.exit(1)
    print(json.dumps({"id": sys.argv[3], "status": os.environ.get("FAKE_STATUS", "Accepted")}))
elif command == "log":
    pathlib.Path(sys.argv[-1]).write_text(json.dumps({"issues": []}))
else:
    raise SystemExit("Unexpected notarization command: " + command)
'''


class NotarizationRecoveryTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.artifact = self.root / "Salient synthetic.zip"
        self.artifact.write_bytes(b"synthetic app archive")
        self.report = self.root / "notary.json"
        self.state = self.root / "state.json"
        self.fake = self.root / "fake_notary.py"
        self.fake.write_text(FAKE_NOTARY)

    def tearDown(self):
        self.temp.cleanup()

    def run_submit(self, **overrides):
        env = dict(os.environ, SALIENT_EDITION="mini", SALIENT_DIST_DIR=str(self.root),
                   RELEASE_SOURCE=str(RELEASE), FAKE_NOTARY=str(self.fake),
                   FAKE_NOTARY_STATE=str(self.state), TEST_ARTIFACT=str(self.artifact),
                   TEST_REPORT=str(self.report))
        env.update(overrides)
        # Replace only the external Apple CLI; execute the production shell function.
        command = '''source "$RELEASE_SOURCE" help >/dev/null
xcrun() { python3 "$FAKE_NOTARY" "$@"; }
submit_and_check "$TEST_ARTIFACT" "$TEST_REPORT"
'''
        return subprocess.run(["/bin/bash", "-c", command], env=env,
                              capture_output=True, text=True, timeout=10)

    def test_interrupted_wait_retains_submission_and_resumes_without_upload(self):
        interrupted = self.run_submit(FAKE_WAIT_FAIL="1")
        self.assertNotEqual(interrupted.returncode, 0)
        first_id = json.loads(self.report.read_text())["id"]
        self.assertTrue(Path(str(self.report) + ".artifact-sha256").is_file())
        resumed = self.run_submit()
        self.assertEqual(resumed.returncode, 0, resumed.stderr)
        self.assertEqual(json.loads(self.report.read_text())["id"], first_id)
        self.assertEqual(json.loads(self.state.read_text())["submissions"], 1)

    def test_changed_archive_gets_new_submission(self):
        self.assertEqual(self.run_submit().returncode, 0)
        self.artifact.write_bytes(b"a different synthetic release")
        self.assertEqual(self.run_submit().returncode, 0)
        self.assertEqual(json.loads(self.state.read_text())["submissions"], 2)

    def test_rejection_saves_log_and_fails(self):
        rejected = self.run_submit(FAKE_STATUS="Invalid")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertIn("Apple did not accept", rejected.stderr)
        self.assertEqual(json.loads(self.report.read_text())["status"], "Invalid")
        self.assertTrue(Path(str(self.report) + ".log.json").is_file())

    def test_same_archive_reuses_saved_submission(self):
        self.assertEqual(self.run_submit().returncode, 0)
        self.assertEqual(self.run_submit().returncode, 0)
        self.assertEqual(json.loads(self.state.read_text())["submissions"], 1)


if __name__ == "__main__":
    unittest.main()
