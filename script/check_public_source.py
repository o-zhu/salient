#!/usr/bin/env python3
"""Check the exact Git index for forbidden publication artifacts.

This is a guardrail, not a substitute for reviewing fixture provenance or using
a dedicated secret scanner. It reads staged blobs, including force-added files;
.gitignore and the working copy cannot hide content that would be committed.
Only paths and rule names are reported, never matching secret values.
"""
import argparse
from pathlib import Path, PurePosixPath
import re
import subprocess
import sys


FORBIDDEN_PARTS = {
    ".build", ".swiftpm", ".codex", ".agents", ".tts-captures", "__pycache__",
    "dist", "target", "imports", "data", "logs", "screenshots", "recordings",
    "captures", "graphify-out", "voice-comparison", "venv", ".venv",
}
FORBIDDEN_SUFFIXES = {
    ".wav", ".m4a", ".mp3", ".aiff", ".caf", ".flac", ".mp4", ".mov",
    ".safetensors", ".gguf", ".mlx", ".aimodel", ".onnx", ".pt", ".pth",
    ".ckpt", ".bin", ".dmg", ".zip", ".gz", ".tar", ".db", ".jsonl",
    ".p12", ".pfx", ".p8", ".key", ".pem", ".cer", ".certsigningrequest",
    ".mobileprovision", ".provisionprofile", ".pyc", ".log",
}
PUBLIC_BINARY_ASSETS = {
    "Assets/AppIcon/AppIcon1024.png", "Assets/AppIcon/AppIconSource.png",
    "Assets/AppIcon/Salient.icns",
}
PRIVATE_SOURCE_PREFIXES = (
    "Sources/SalientLauncher/", "Sources/SalientStudyLibraryMaintenance/",
    "Sources/SalientStudyPackGenerator/", "Sources/SalientCore/Features/StudyLibrary/",
    "Sources/SalientCore/Features/StudyIntelligence/", "Sources/SalientCore/Features/StudyPacks/",
    "Sources/SalientCore/Services/AI/",
)
PRIVATE_SOURCE_FILES = {
    "Sources/SalientCore/Resources/local_librarian_helper.py",
    "Sources/Salient/App/LibrarianChatView.swift", "Sources/Salient/App/StudyLibraryView.swift",
    "Sources/Salient/App/PodcastAutomation.swift", "Sources/Salient/App/PodcastTranscriptsView.swift",
}
PRIVATE_SWIFT_IMPLEMENTATIONS = re.compile(
    r"\b(?:StudyLibraryStore|DailyPodcastBuilder|LocalTextModelRuntimeManager|"
    r"LibrarianChatSessionSnapshot|SavedBrowserInfoResult|StudyPackPipeline)\b"
)
TEXT_RULES = {
    "private signing key": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH |DSA )?PRIVATE KEY-----"),
    "provider credential": re.compile(
        r"\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|"
        r"hf_[A-Za-z0-9]{20,}|sk-(?:proj-|ant-)?[A-Za-z0-9_-]{24,})\b"
    ),
    "AWS access key": re.compile(r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b"),
    "authenticated URL": re.compile(r"https?://[^\s/:@]+:[^\s/@]+@"),
    # Synthetic paths used by redaction tests are intentionally allowed.
    "personal home path": re.compile(r"/(?:Users|home)/(?!example(?:/|\b))([A-Za-z0-9_.-]+)/"),
    "Git LFS pointer": re.compile(r"^version https://git-lfs.github.com/spec/v1", re.M),
}


def violations(path, content, mode="100644"):
    p = PurePosixPath(path)
    problems = []
    if path.startswith(PRIVATE_SOURCE_PREFIXES) or path in PRIVATE_SOURCE_FILES:
        problems.append("private application source; this repository contains only the reader")
    if mode not in {"100644", "100755"}:
        problems.append("symlink or submodule; publication must be self-contained")
    if any(part in FORBIDDEN_PARTS or part.endswith((".app", ".mlmodelc", ".mlpackage")) for part in p.parts):
        problems.append("private or generated directory")
    if p.name == ".DS_Store" or p.name.startswith(".env") or ".sqlite" in p.name or ".keychain" in p.name:
        problems.append("private state or credentials")
    if p.suffix.lower() in FORBIDDEN_SUFFIXES:
        problems.append("model, recording, archive, credential, or generated file")
    if len(content) > 10 * 1024 * 1024:
        problems.append("file larger than source publication limit (10 MiB)")
    if path not in PUBLIC_BINARY_ASSETS:
        try:
            text = content.decode("utf-8")
        except UnicodeDecodeError:
            problems.append("unreviewed binary asset")
        else:
            if path.startswith("Sources/") and p.suffix == ".swift" and PRIVATE_SWIFT_IMPLEMENTATIONS.search(text):
                problems.append("private application implementation in public reader source")
            if "\0" in text:
                problems.append("binary content")
            for name, pattern in TEXT_RULES.items():
                if pattern.search(text):
                    problems.append(name)
    return problems


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--staged", action="store_true", help="Check the full index (also the default).")
    parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    listing = subprocess.check_output(["git", "ls-files", "--stage", "-z"], cwd=root)
    count, failures = 0, []
    for entry in listing.split(b"\0"):
        if not entry:
            continue
        metadata, raw_path = entry.split(b"\t", 1)
        mode, oid, stage = metadata.decode("ascii").split()
        path = raw_path.decode("utf-8")
        if stage != "0":
            failures.append((path, "unresolved merge"))
            continue
        content = subprocess.check_output(["git", "cat-file", "blob", oid], cwd=root)
        count += 1
        failures.extend((path, reason) for reason in violations(path, content, mode))
    if count == 0:
        print("No indexed source files found. Stage the reviewed files first.", file=sys.stderr)
        return 1
    for path, reason in failures:
        print(f"{path}: {reason}", file=sys.stderr)
    if failures:
        print(f"Publication check failed: {len(failures)} finding(s).", file=sys.stderr)
        return 1
    print(f"Publication check passed: {count} indexed files; no forbidden artifacts or credential patterns.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
