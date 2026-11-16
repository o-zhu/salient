#!/usr/bin/env python3
"""Offline notices for the locked native worker dependency graph, including C++."""
import json
from pathlib import Path
import subprocess
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    native = root / "Native/PocketWorker"
    graph = json.loads(subprocess.check_output([
        "cargo", "metadata", "--offline", "--locked", "--format-version", "1",
        "--filter-platform", "aarch64-apple-darwin", "--manifest-path", str(native / "Cargo.toml")
    ]))
    resolved = {node["id"] for node in graph["resolve"]["nodes"]}
    output = ["Salient Pocket native worker — third-party notices\n\n",
              "Includes runtime and build dependencies from Cargo.lock.\n",
              "Bundled English model and Alba voice attribution: PocketTTS/NOTICES.md.\n\n",
              "Kyutai Pocket TTS v4.0.1, adapted for private offline pipes:\n",
              (native / "LICENSE-Pocket").read_text(), "\n"]
    for package in sorted(graph["packages"], key=lambda p: (p["name"], p["version"])):
        if package["id"] not in resolved or package["name"] == "salient-pocket-worker":
            continue
        folder = Path(package["manifest_path"]).parent
        files = sorted(p for p in folder.rglob("*") if p.is_file() and p.name.lower().startswith(
            ("license", "licence", "copying", "notice", "copyright")))
        if not files:
            files = sorted((native / "licenses").glob(package["name"] + "-*"))
        if not files:
            raise SystemExit("Missing native dependency license: " + package["name"])
        output.append("\n" + "=" * 72 + "\n" + package["name"] + " " + package["version"] + "\n"
                      + (package["repository"] or "") + "\nLicense expression: " + (package["license"] or "") + "\n")
        seen = set()
        for notice in files:
            text = notice.read_text(encoding="utf-8")
            if text not in seen:
                output.extend(["\n" + notice.name + "\n", text, "\n"])
                seen.add(text)
    toolchain = Path(subprocess.check_output(["rustc", "--print", "sysroot"], text=True).strip())
    copyright_file = toolchain / "share/doc/rustc/COPYRIGHT-library.html"
    if not copyright_file.is_file():
        raise SystemExit("Missing Rust standard-library copyright inventory")
    from html.parser import HTMLParser
    class Text(HTMLParser):
        def __init__(self):
            super().__init__()
            self.parts = []
        def handle_data(self, data):
            self.parts.append(data)
    parser = Text()
    parser.feed(copyright_file.read_text())
    output.extend(["\nRust standard library\n", "".join(parser.parts), "\n"])
    Path(sys.argv[1]).write_text("".join(output), encoding="utf-8")


if __name__ == "__main__":
    main()
