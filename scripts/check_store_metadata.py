#!/usr/bin/env python3
"""Checks the App Store metadata draft in AppStore/ against App Store Connect's limits.

    scripts/check_store_metadata.py

The files follow fastlane deliver's layout (AppStore/metadata/<locale>/<field>.txt), one field per file; a single
trailing line break is not part of the value. Limits, from App Store Connect Help (checked 5 November 2026):
- Name: 2 to 30 characters; subtitle: up to 30 characters.
  https://developer.apple.com/help/app-store-connect/reference/app-information/app-information
- Promotional text: up to 170 characters; description: up to 4000 characters, plain text (no HTML); keywords: up
  to 100 bytes, each keyword more than two characters, not repeating the app's name; what's new: up to 4000
  characters; App Review notes: up to 4000 bytes.
  https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information
Characters are counted as Unicode code points and as UTF-16 code units, and the larger count must fit, since Apple
does not say which it counts. Keywords and review notes are counted in UTF-8 bytes.

Runs with the python3 that ships with the Xcode command line tools (3.9).
"""

from __future__ import annotations

import os
import re
import sys
from typing import Dict, List, Optional, Tuple

METADATA = os.path.join("AppStore", "metadata")
REVIEW_NOTES = os.path.join("AppStore", "review-notes.md")
LOCALES = ["en-US", "ru"]
# The repository on GitHub: every URL in the metadata points into it, and a privacy policy URL names a file in it.
REPOSITORY_URL = "https://github.com/pandamy619/ShowMyCopy"

CHARACTERS = "characters"
BYTES = "bytes"
# field: (minimum, maximum, unit)
LIMITS: Dict[str, Tuple[int, int, str]] = {
    "name": (2, 30, CHARACTERS),
    "subtitle": (0, 30, CHARACTERS),
    "promotional_text": (0, 170, CHARACTERS),
    "description": (1, 4000, CHARACTERS),
    "keywords": (1, 100, BYTES),
    "release_notes": (0, 4000, CHARACTERS),
    "support_url": (1, 2000, CHARACTERS),
    "privacy_url": (1, 2000, CHARACTERS),
    "marketing_url": (0, 2000, CHARACTERS),
}
URL_FIELDS = ("support_url", "privacy_url", "marketing_url")
REVIEW_NOTES_MAXIMUM_BYTES = 4000
MINIMUM_KEYWORD_CHARACTERS = 3  # "each greater than two characters"
_HTML = re.compile(r"<\s*/?\s*[A-Za-z][^>]*>|&[A-Za-z]+;|&#\d+;")


def length(value: str, unit: str) -> int:
    if unit == BYTES:
        return len(value.encode("utf-8"))
    return max(len(value), len(value.encode("utf-16-le")) // 2)


def read_value(path: str) -> Tuple[Optional[str], Optional[str]]:
    """(the field's value, an error)."""
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except (OSError, UnicodeDecodeError) as error:
        return None, "cannot read %s: %s" % (path, error)
    if text.endswith("\r\n"):
        text = text[:-2]
    elif text.endswith("\n"):
        text = text[:-1]
    return text, None


def check_keywords(value: str, name: str, where: str) -> List[str]:
    errors = []
    keywords = value.split(",")
    seen = set()
    name_words = {word.lower() for word in re.findall(r"\w+", name)}
    for keyword in keywords:
        if keyword != keyword.strip():
            errors.append("%s: keyword %r has spaces around it; they count toward the 100 bytes" % (where, keyword))
        keyword = keyword.strip()
        if not keyword:
            errors.append("%s: empty keyword" % where)
            continue
        if len(keyword) < MINIMUM_KEYWORD_CHARACTERS:
            errors.append("%s: keyword %r must be more than two characters" % (where, keyword))
        if keyword.lower() in seen:
            errors.append("%s: keyword %r is listed twice" % (where, keyword))
        seen.add(keyword.lower())
        repeated = sorted(name_words & {word.lower() for word in re.findall(r"\w+", keyword)})
        if repeated:
            errors.append("%s: keyword %r repeats the app's name (%s); the name is searched already"
                          % (where, keyword, ", ".join(repeated)))
    return errors


def check_url(value: str, field: str, root: str, where: str) -> List[str]:
    if not value:
        return []
    if value != value.strip() or "\n" in value:
        return ["%s: must be one URL on one line" % where]
    if not (value == REPOSITORY_URL or value.startswith(REPOSITORY_URL + "/")):
        return ["%s: must point into %s, found %s" % (where, REPOSITORY_URL, value)]
    if field == "privacy_url":
        match = re.match(re.escape(REPOSITORY_URL) + r"/blob/main/([A-Za-z0-9_.\-/]+\.md)$", value)
        if match is None:
            return ["%s: must be %s/blob/main/<file>.md, the rendered policy" % (where, REPOSITORY_URL)]
        if not os.path.isfile(os.path.join(root, match.group(1))):
            return ["%s: %s is not in the repository" % (where, match.group(1))]
    return []


def check_locale(root: str, locale: str) -> List[str]:
    folder = os.path.join(root, METADATA, locale)
    if not os.path.isdir(folder):
        return ["%s is missing" % os.path.join(METADATA, locale)]
    errors = []
    present = sorted(name for name in os.listdir(folder) if not name.startswith("."))
    for name in present:
        if not name.endswith(".txt") or name[:-4] not in LIMITS:
            errors.append("%s: unknown file %s" % (os.path.join(METADATA, locale), name))
    values: Dict[str, str] = {}
    for field, (minimum, maximum, unit) in LIMITS.items():
        where = os.path.join(METADATA, locale, field + ".txt")
        path = os.path.join(root, where)
        if not os.path.isfile(path):
            if minimum > 0:
                errors.append("%s is missing" % where)
            continue
        value, error = read_value(path)
        if value is None:
            errors.append(error or "cannot read %s" % where)
            continue
        values[field] = value
        count = length(value, unit)
        if count < minimum or count > maximum:
            errors.append("%s: %d %s, must be %d to %d" % (where, count, unit, minimum, maximum))
        if field in URL_FIELDS:
            errors.extend(check_url(value, field, root, where))
        elif field != "description" and field != "release_notes" and "\n" in value:
            errors.append("%s: must be one line" % where)
        if field in ("description", "release_notes", "promotional_text") and _HTML.search(value):
            errors.append("%s: App Store Connect shows plain text only, found HTML" % where)
    if "keywords" in values:
        errors.extend(check_keywords(values["keywords"], values.get("name", ""), os.path.join(METADATA, locale,
                                                                                             "keywords.txt")))
    return errors


def check_review_notes(root: str) -> List[str]:
    path = os.path.join(root, REVIEW_NOTES)
    try:
        with open(path, "rb") as handle:
            data = handle.read()
    except OSError as error:
        return ["cannot read %s: %s" % (REVIEW_NOTES, error)]
    try:
        data.decode("utf-8")
    except UnicodeDecodeError as error:
        return ["%s is not UTF-8: %s" % (REVIEW_NOTES, error)]
    if len(data) > REVIEW_NOTES_MAXIMUM_BYTES:
        return ["%s: %d bytes, App Review notes take at most %d" % (REVIEW_NOTES, len(data),
                                                                    REVIEW_NOTES_MAXIMUM_BYTES)]
    return []


def run_checks(root: str) -> List[str]:
    errors = []
    folder = os.path.join(root, METADATA)
    if os.path.isdir(folder):
        for name in sorted(os.listdir(folder)):
            if not name.startswith(".") and name not in LOCALES:
                errors.append("%s: unknown locale %s" % (METADATA, name))
    for locale in LOCALES:
        errors.extend(check_locale(root, locale))
    errors.extend(check_review_notes(root))
    return errors


def report(root: str) -> List[str]:
    """One line per field: its length and limit, for the person filling in App Store Connect."""
    lines = []
    for locale in LOCALES:
        for field, (_, maximum, unit) in LIMITS.items():
            path = os.path.join(root, METADATA, locale, field + ".txt")
            if os.path.isfile(path):
                value, _ = read_value(path)
                if value is not None:
                    lines.append("%-6s %-17s %4d / %d %s" % (locale, field, length(value, unit), maximum, unit))
    return lines


def main(argv: List[str]) -> int:
    if argv not in ([], ["--report"]):
        print("usage: check_store_metadata.py [--report]", file=sys.stderr)
        return 2
    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    if argv:
        print("\n".join(report(root)))
    errors = run_checks(root)
    for error in errors:
        print("error: " + error, file=sys.stderr)
    if errors:
        return 1
    print("store metadata checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
