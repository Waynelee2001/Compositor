#!/usr/bin/env python3
"""Download the pinned official Apple Silicon Codex release and verify its published SHA-256."""
from __future__ import annotations
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

TAG = "rust-v0.160.1"
ASSET = "codex-aarch64-apple-darwin.tar.gz"

def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--out", type=Path, required=True)
    args = parser.parse_args()
    target = args.out.resolve(); target.mkdir(parents=True, exist_ok=True)
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "Compositor-Codex-CI"}
    token = os.environ.get("GITHUB_TOKEN")
    if token: headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(f"https://api.github.com/repos/openai/codex/releases/tags/{TAG}", headers=headers)
    with urllib.request.urlopen(request, timeout=45) as response: release = json.load(response)
    asset = next(asset for asset in release["assets"] if asset["name"] == ASSET)
    digest = asset.get("digest", "")
    if not digest.startswith("sha256:"): raise RuntimeError("Release asset has no SHA-256 digest")
    url = asset["browser_download_url"]
    if not url.startswith(f"https://github.com/openai/codex/releases/download/{TAG}/"):
        raise RuntimeError("Unexpected release download URL")
    with tempfile.TemporaryDirectory() as directory:
        archive = Path(directory) / ASSET
        with urllib.request.urlopen(url, timeout=90) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        actual = hashlib.sha256(archive.read_bytes()).hexdigest()
        if actual != digest.split(":", 1)[1]: raise RuntimeError("Release checksum mismatch")
        with tarfile.open(archive, "r:gz") as source:
            members = [member for member in source.getmembers()
                       if member.isfile() and Path(member.name).name in {"codex", "codex-aarch64-apple-darwin"}]
            if len(members) != 1: raise RuntimeError("Expected exactly one Codex executable")
            stream = source.extractfile(members[0])
            if stream is None: raise RuntimeError("Missing executable bytes")
            with stream, (target / "codex").open("wb") as out: shutil.copyfileobj(stream, out)
    (target / "codex").chmod(0o755)
    with urllib.request.urlopen(f"https://raw.githubusercontent.com/openai/codex/{TAG}/LICENSE", timeout=30) as response:
        (target / "Codex-LICENSE").write_bytes(response.read())
    (target / "release.json").write_text(json.dumps({"tag": TAG, "asset": ASSET, "sha256": actual}, indent=2) + "\n")
    print(f"Verified official {TAG}: {ASSET}")

if __name__ == "__main__":
    main()
