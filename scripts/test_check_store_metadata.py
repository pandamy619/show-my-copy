#!/usr/bin/env python3
"""Canary tests for scripts/check_store_metadata.py: prove that each limit can actually fail.

Run with `make security-selftest`. Works on Linux and macOS. Each test copies AppStore/ and the privacy policies
into a temporary directory and changes the copy.
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

import check_store_metadata as checker  # noqa: E402


class RealRepositoryTests(unittest.TestCase):
    def test_repository_passes(self) -> None:
        self.assertEqual(checker.run_checks(REPO), [])

    def test_every_field_has_a_file_in_every_locale(self) -> None:
        for locale in checker.LOCALES:
            for field in checker.LIMITS:
                with self.subTest(locale=locale, field=field):
                    self.assertTrue(os.path.isfile(os.path.join(REPO, checker.METADATA, locale, field + ".txt")))


class MetadataTests(unittest.TestCase):
    def setUp(self) -> None:
        self.root = tempfile.mkdtemp(prefix="metadata-selftest-")
        self.addCleanup(shutil.rmtree, self.root, True)
        shutil.copytree(os.path.join(REPO, "AppStore"), os.path.join(self.root, "AppStore"))
        for name in ("PRIVACY.md", "PRIVACY.ru.md"):
            shutil.copy(os.path.join(REPO, name), os.path.join(self.root, name))

    def write(self, locale: str, field: str, value: str) -> None:
        with open(os.path.join(self.root, checker.METADATA, locale, field + ".txt"), "w", encoding="utf-8") as handle:
            handle.write(value + "\n")

    def assertFails(self, needle: str) -> None:
        errors = checker.run_checks(self.root)
        self.assertTrue(any(needle in error for error in errors), "expected %r in %r" % (needle, errors))

    def test_copy_passes(self) -> None:
        self.assertEqual(checker.run_checks(self.root), [])

    def test_limits_are_apples(self) -> None:
        self.assertEqual(checker.LIMITS["name"], (2, 30, checker.CHARACTERS))
        self.assertEqual(checker.LIMITS["subtitle"][1:], (30, checker.CHARACTERS))
        self.assertEqual(checker.LIMITS["promotional_text"][1:], (170, checker.CHARACTERS))
        self.assertEqual(checker.LIMITS["description"][1:], (4000, checker.CHARACTERS))
        self.assertEqual(checker.LIMITS["keywords"][1:], (100, checker.BYTES))
        self.assertEqual(checker.LIMITS["release_notes"][1:], (4000, checker.CHARACTERS))
        self.assertEqual(checker.REVIEW_NOTES_MAXIMUM_BYTES, 4000)

    def test_each_limit_fails_one_past_it(self) -> None:
        for field in ("name", "subtitle", "promotional_text", "description", "release_notes"):
            with self.subTest(field=field):
                maximum = checker.LIMITS[field][1]
                self.write("en-US", field, "a" * maximum)
                self.assertNotIn(field, " ".join(checker.run_checks(self.root)))
                self.write("en-US", field, "a" * (maximum + 1))
                self.assertFails("%s.txt: %d characters, must be" % (field, maximum + 1))
                shutil.copy(os.path.join(REPO, checker.METADATA, "en-US", field + ".txt"),
                            os.path.join(self.root, checker.METADATA, "en-US", field + ".txt"))

    def test_cyrillic_counts_as_one_character_each(self) -> None:
        self.write("ru", "subtitle", "я" * 30)
        self.assertEqual(checker.run_checks(self.root), [])

    def test_characters_outside_the_bmp_count_twice(self) -> None:
        self.write("en-US", "subtitle", "a" * 28 + "\U0001F4CB" * 2)
        self.assertFails("subtitle.txt: 32 characters")

    def test_name_too_short_fails(self) -> None:
        self.write("en-US", "name", "S")
        self.assertFails("name.txt: 1 characters, must be 2 to 30")

    def test_keywords_count_bytes_not_characters(self) -> None:
        value = "буфер обмена,история,вставка,менеджер буфера,без сети,скопированное"
        self.assertLessEqual(len(value), 100)
        self.write("ru", "keywords", value)
        self.assertFails("keywords.txt: %d bytes, must be 1 to 100" % len(value.encode("utf-8")))

    def test_short_keyword_fails(self) -> None:
        self.write("en-US", "keywords", "clipboard,ok")
        self.assertFails("keyword 'ok' must be more than two characters")

    def test_keyword_repeating_the_name_fails(self) -> None:
        self.write("en-US", "keywords", "clipboard,copy paste")
        self.assertFails("repeats the app's name (copy)")

    def test_duplicate_keyword_fails(self) -> None:
        self.write("en-US", "keywords", "clipboard,Clipboard")
        self.assertFails("is listed twice")

    def test_spaces_around_keywords_fail(self) -> None:
        self.write("en-US", "keywords", "clipboard, history")
        self.assertFails("has spaces around it")

    def test_empty_keyword_fails(self) -> None:
        self.write("en-US", "keywords", "clipboard,,history")
        self.assertFails("empty keyword")

    def test_html_in_the_description_fails(self) -> None:
        self.write("en-US", "description", "A <b>bold</b> claim.")
        self.assertFails("found HTML")

    def test_two_lines_in_a_one_line_field_fail(self) -> None:
        self.write("en-US", "subtitle", "Private\nclipboard")
        self.assertFails("subtitle.txt: must be one line")

    def test_missing_required_field_fails(self) -> None:
        os.remove(os.path.join(self.root, checker.METADATA, "ru", "description.txt"))
        self.assertFails("ru/description.txt is missing")

    def test_unknown_file_fails(self) -> None:
        self.write("ru", "title", "Show My Copy")
        self.assertFails("unknown file title.txt")

    def test_unknown_locale_fails(self) -> None:
        os.makedirs(os.path.join(self.root, checker.METADATA, "de-DE"))
        self.assertFails("unknown locale de-DE")

    def test_url_outside_the_repository_fails(self) -> None:
        self.write("en-US", "support_url", "https://example.com/support")
        self.assertFails("must point into %s" % checker.REPOSITORY_URL)

    def test_privacy_url_to_a_missing_file_fails(self) -> None:
        os.remove(os.path.join(self.root, "PRIVACY.ru.md"))
        self.assertFails("PRIVACY.ru.md is not in the repository")

    def test_privacy_url_that_is_not_a_rendered_file_fails(self) -> None:
        self.write("en-US", "privacy_url", checker.REPOSITORY_URL + "/raw/main/PRIVACY.md")
        self.assertFails("must be %s/blob/main/<file>.md" % checker.REPOSITORY_URL)

    def test_review_notes_over_4000_bytes_fail(self) -> None:
        with open(os.path.join(self.root, checker.REVIEW_NOTES), "w", encoding="utf-8") as handle:
            handle.write("я" * 2001)
        self.assertFails("4002 bytes, App Review notes take at most 4000")


if __name__ == "__main__":
    unittest.main(verbosity=1)
