#!/usr/bin/env python3
"""Tests for scripts/prepare_release.py: a tag becomes a release only when it matches the version and the changelog.

Run with `make security-selftest`. Works on Linux and macOS. Each test copies the version settings and the
changelog into a temporary directory and changes the copy.
"""

from __future__ import annotations

import os
import shutil
import sys
import tempfile
import unittest

SCRIPTS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(SCRIPTS)
sys.path.insert(0, SCRIPTS)
sys.dont_write_bytecode = True  # keep scripts/ free of __pycache__

import prepare_release as release  # noqa: E402

CHANGELOG = """# Changelog

## [0.2.0] - 2026-12-01

- Second.

## [0.1.0] - 2026-11-09

First version.

- One.
"""


class FakeRepositoryTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = tempfile.mkdtemp()
        os.makedirs(os.path.join(self.root, "Config"))
        os.makedirs(os.path.join(self.root, "ShowMyCopy.xcodeproj"))
        self.write("Config/Shared.xcconfig", "// Version\nMARKETING_VERSION = 0.1.0\nCURRENT_PROJECT_VERSION = 1\n")
        self.write("Config/Tests.xcconfig", "#include \"Shared.xcconfig\"\n")
        self.write("ShowMyCopy.xcodeproj/project.pbxproj", "{ buildSettings = { PRODUCT_NAME = ShowMyCopy; }; }\n")
        self.write("CHANGELOG.md", CHANGELOG)

    def tearDown(self) -> None:
        shutil.rmtree(self.root)

    def write(self, path: str, text: str) -> None:
        with open(os.path.join(self.root, path), "w", encoding="utf-8") as handle:
            handle.write(text)

    def test_matching_tag_prints_only_its_section(self) -> None:
        self.assertEqual(release.prepare(self.root, "v0.1.0"), "First version.\n\n- One.")

    def test_tag_must_be_v_and_three_numbers(self) -> None:
        for tag in ["0.1.0", "v0.1", "v3", "v3.1", "v0.1.0-beta", "v0.1.0 "]:
            with self.assertRaises(SystemExit, msg=tag):
                release.prepare(self.root, tag)

    def test_tag_must_match_the_version(self) -> None:
        with self.assertRaises(SystemExit):
            release.prepare(self.root, "v0.2.0")

    def test_version_set_twice_differently_is_refused(self) -> None:
        self.write("Config/Widget.xcconfig", "MARKETING_VERSION = 0.0.9\n")
        with self.assertRaises(SystemExit):
            release.prepare(self.root, "v0.1.0")

    def test_version_set_in_the_project_counts(self) -> None:
        self.write("ShowMyCopy.xcodeproj/project.pbxproj", "{ MARKETING_VERSION = 0.0.9; }\n")
        with self.assertRaises(SystemExit):
            release.prepare(self.root, "v0.1.0")

    def test_missing_or_empty_section_is_refused(self) -> None:
        self.write("CHANGELOG.md", "# Changelog\n\n## [Unreleased]\n\n- Something.\n")
        with self.assertRaises(SystemExit):
            release.prepare(self.root, "v0.1.0")
        self.write("CHANGELOG.md", "# Changelog\n\n## [0.1.0] - 2026-11-09\n\n## [0.0.1]\n\n- Old.\n")
        with self.assertRaises(SystemExit):
            release.prepare(self.root, "v0.1.0")


class RealRepositoryTests(unittest.TestCase):
    def test_repository_has_one_version(self) -> None:
        self.assertEqual(len(release.project_versions(REPO)), 1)


if __name__ == "__main__":
    unittest.main()
