#!/usr/bin/env python3
"""Fails when a string in the catalog lacks a Russian translation, a plural form or a placeholder."""

import json
import re
import sys
from pathlib import Path

CATALOG = Path(__file__).resolve().parent.parent / "ShowMyCopy" / "Localizable.xcstrings"
PLACEHOLDER = re.compile(r"%(?:\d+\$)?(?:@|lld|ld|d|f)")
PLURAL_FORMS = {"en": ("one", "other"), "ru": ("one", "few", "many", "other")}


def plural_problems(key, language, forms):
    expected = len(PLACEHOLDER.findall(key))
    for form in PLURAL_FORMS[language]:
        unit = forms.get(form, {}).get("stringUnit", {})
        value = unit.get("value", "")
        if unit.get("state") != "translated" or not value:
            yield f"missing {language} plural form {form!r}: {key!r}"
        # A plural form may leave out the number it agrees with, as in "This removes your oldest item."
        elif len(PLACEHOLDER.findall(value)) not in (expected, expected - 1):
            yield f"placeholder mismatch in {language} plural form {form!r}: {key!r}"


def problems(catalog):
    for key, entry in sorted(catalog["strings"].items()):
        if entry.get("shouldTranslate") is False:
            continue
        localizations = entry.get("localizations", {})
        is_plural = any("plural" in loc.get("variations", {}) for loc in localizations.values())
        if is_plural:
            for language in PLURAL_FORMS:
                forms = localizations.get(language, {}).get("variations", {}).get("plural")
                if forms is None:
                    yield f"missing {language} plural variations: {key!r}"
                else:
                    yield from plural_problems(key, language, forms)
            continue
        unit = localizations.get("ru", {}).get("stringUnit", {})
        value = unit.get("value", "")
        if unit.get("state") != "translated" or not value:
            yield f"missing Russian translation: {key!r}"
        elif len(PLACEHOLDER.findall(key)) != len(PLACEHOLDER.findall(value)):
            yield f"placeholder mismatch: {key!r}"


def main():
    found = list(problems(json.loads(CATALOG.read_text(encoding="utf-8"))))
    for problem in found:
        print(problem, file=sys.stderr)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
