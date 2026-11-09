#!/usr/bin/env python3
"""Checks that the app's version matches a release tag and prints that version's CHANGELOG section.

    scripts/prepare_release.py v0.1.0 > notes.md

Used by .github/workflows/release.yml before anything is built, so a tag that does not match the version in
Config/Shared.xcconfig, or a version with no CHANGELOG section, never becomes a release. Runs with the python3 that
ships with the Xcode command line tools (3.9), so no newer syntax.
"""

from __future__ import annotations

import os
import re
import sys
from typing import Optional, Set

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VERSION_PATTERN = re.compile(r"^\d+\.\d+\.\d+$")
# Anywhere in a line, so a setting is never missed; a comment that looks like a setting fails the release loudly.
SETTING_PATTERN = re.compile(r"\bMARKETING_VERSION\s*(?:\[[^\]]*\])?\s*=\s*([^;/\s]+)")


def project_versions(repo: str) -> Set[str]:
    """Every MARKETING_VERSION set in the .xcconfig files or the project. A release needs exactly one."""
    texts = []
    config = os.path.join(repo, "Config")
    for name in sorted(os.listdir(config)):
        if name.endswith(".xcconfig"):
            with open(os.path.join(config, name), encoding="utf-8") as handle:
                texts.append(handle.read())
    with open(os.path.join(repo, "ShowMyCopy.xcodeproj", "project.pbxproj"), encoding="utf-8") as handle:
        texts.append(handle.read())
    versions = set()
    for text in texts:
        versions.update(value.strip('"') for value in SETTING_PATTERN.findall(text))
    return versions


def release_notes(repo: str, version: str) -> Optional[str]:
    """The text under `## [version]` in CHANGELOG.md, up to the next `## ` heading."""
    with open(os.path.join(repo, "CHANGELOG.md"), encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    heading = re.compile(r"^## \[" + re.escape(version) + r"\]")
    start = next((index for index, line in enumerate(lines) if heading.match(line)), None)
    if start is None:
        return None
    end = next((index for index in range(start + 1, len(lines)) if lines[index].startswith("## ")), len(lines))
    notes = "\n".join(lines[start + 1 : end]).strip()
    return notes or None


def prepare(repo: str, tag: str) -> str:
    """The release notes when the tag can be released; otherwise raises SystemExit with the reason."""
    if not tag.startswith("v") or not VERSION_PATTERN.match(tag[1:]):
        raise SystemExit("tag %r is not vX.Y.Z" % tag)
    version = tag[1:]
    versions = project_versions(repo)
    if versions != {version}:
        raise SystemExit("MARKETING_VERSION %s does not match tag %s" % (sorted(versions), tag))
    notes = release_notes(repo, version)
    if notes is None:
        raise SystemExit("CHANGELOG.md has no section for %s" % version)
    return notes


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: prepare_release.py vX.Y.Z")
    print(prepare(REPO, sys.argv[1]))


if __name__ == "__main__":
    main()
