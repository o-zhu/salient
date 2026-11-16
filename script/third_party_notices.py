#!/usr/bin/env python3
"""Collect notices from the exact resolved Swift dependencies, without network access."""
import json
from pathlib import Path
import sys


def main():
    root = Path(__file__).resolve().parent.parent
    pins = json.loads((root / "Package.resolved").read_text())["pins"]
    sections = [
        "Salient — Third-Party Notices\n\n"
        "This inventory includes the resolved Swift package dependency graph, including "
        "build-time tools. The native Pocket worker has a separate Pocket Runtime Notices.txt. "
        "The bundled Pocket stock model and Alba voice have their own attributions in "
        "PocketTTS/NOTICES.md. Optional Qwen models and Python runtimes are downloaded "
        "separately and retain their upstream licenses.\n"
    ]
    for pin in sorted(pins, key=lambda item: item["identity"]):
        name = pin["identity"]
        checkout = root / ".build" / "checkouts" / name
        notices = sorted(
            p for p in checkout.iterdir()
            if p.is_file() and p.name.lower().startswith(("license", "licence", "notice", "copying"))
        )
        if not any(p.name.lower().startswith(("license", "licence", "copying")) for p in notices):
            raise SystemExit("Missing license for resolved dependency: " + name)
        state = pin["state"]
        sections.append("\n" + "=" * 72 + "\n" + name + " " + state.get("version", "")
                        + "\n" + pin["location"] + "\nRevision: " + state["revision"] + "\n")
        for notice in notices:
            sections.append("\n" + notice.name + "\n\n" + notice.read_text(encoding="utf-8") + "\n")
    Path(sys.argv[1]).write_text("".join(sections), encoding="utf-8")


if __name__ == "__main__":
    main()
