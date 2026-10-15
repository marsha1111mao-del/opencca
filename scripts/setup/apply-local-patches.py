#!/usr/bin/env python3
"""Restore the reviewed changes to pinned upstream OpenCCA components."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys


ROOT = Path(__file__).resolve().parents[2]


def git(repo, *args):
    return subprocess.run(
        ["git", "-C", str(repo), *args], capture_output=True, text=True
    )


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def restore(check=False):
    manifest = json.loads((ROOT / "patches/manifest.json").read_text())
    # Validate the complete plan before changing any component.
    pending = []
    for entry in manifest["patches"]:
        repo = ROOT / entry["repository"]
        patch = ROOT / entry["patch"]
        head = git(repo, "rev-parse", "HEAD")
        if head.returncode or head.stdout.strip() != entry["base_commit"]:
            raise ValueError(f"{entry['repository']}: initialize the pinned submodule first")
        if digest(patch) != entry["sha256"]:
            raise ValueError(f"{entry['patch']}: patch checksum mismatch")
        if git(repo, "apply", "--reverse", "--check", str(patch)).returncode == 0:
            actual = subprocess.check_output([
                "git", "-C", str(repo), "diff", "--binary",
                "--no-ext-diff", "--no-textconv", "HEAD"
            ])
            if hashlib.sha256(actual).hexdigest() != entry["sha256"]:
                raise ValueError(
                    f"{entry['repository']}: changes differ from the published patch"
                )
            print(f"APPLIED {entry['repository']}")
        elif git(repo, "apply", "--check", str(patch)).returncode == 0:
            if check:
                raise ValueError(f"{entry['repository']}: required patch is not applied")
            pending.append((repo, patch))
        else:
            raise ValueError(f"{entry['repository']}: local changes conflict with required patch")
    copies = []
    for entry in manifest["copies"]:
        source = ROOT / entry["source"]
        target = ROOT / entry["destination"]
        if not source.is_file() or digest(source) != entry["sha256"]:
            raise ValueError(f"{entry['source']}: missing or incorrect pinned loader input")
        if target.is_file() and digest(target) == entry["sha256"]:
            print(f"APPLIED {entry['destination']}")
        elif check:
            raise ValueError(f"{entry['destination']}: required loader is not installed")
        else:
            copies.append((source, target))
    for repo, patch in pending:
        result = git(repo, "apply", str(patch))
        if result.returncode:
            raise ValueError(result.stderr)
        print(f"RESTORED {repo.relative_to(ROOT)}")
    for source, target in copies:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(source.read_bytes())
        print(f"RESTORED {target.relative_to(ROOT)}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify without changing files")
    args = parser.parse_args()
    try:
        restore(args.check)
    except (OSError, ValueError, KeyError) as error:
        sys.exit(str(error))
