#!/usr/bin/env python3
"""Validate shared translations and every literal localization key in the owned source tree."""
import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RESOURCES = ROOT / "Packages/RimeEngine/Sources/RimeEngine/Resources"
ENTRY = re.compile(r'^("(?:\\.|[^"\\])*") = ("(?:\\.|[^"\\])*");$', re.M)
CALL = re.compile(r'RimeLocalization\.(?:text|message|key)\(\s*"')


def read_string(source, start):
    """Extract a Swift source key, consuming balanced interpolation expressions and nested strings."""
    key = ""
    slots = 0
    index = start + 1
    while index < len(source):
        if source[index] == '"':
            return key, index + 1
        if source[index:index + 2] == "\\(":
            key += "{" + str(slots) + "}"
            slots += 1
            index += 2
            depth = 1
            while depth:
                if source[index] == '"':
                    _, index = read_string(source, index)
                else:
                    depth += (source[index] == "(") - (source[index] == ")")
                    index += 1
        elif source[index] == "\\":
            escaped = source[index + 1]
            key += {"n": "\n", "t": "\t", "r": "\r"}.get(escaped, escaped)
            index += 2
        else:
            key += source[index]
            index += 1
    raise ValueError("Unterminated Swift string")


def source_keys():
    keys = set()
    for directory in ("arkey", "ARKeyboard", "KeyboardUI", "Packages/RimeEngine/Sources/RimeEngine"):
        for path in (ROOT / directory).glob("*.swift"):
            source = re.sub(r"(?m)^\s*//.*$", "", path.read_text())
            for match in CALL.finditer(source):
                key, _ = read_string(source, match.end() - 1)
                if key:
                    keys.add(key)
    return keys


def read_catalog(language):
    path = RESOURCES / (language + ".lproj") / "Localizable.strings"
    pairs = [(json.loads(key), json.loads(value)) for key, value in ENTRY.findall(path.read_text())]
    assert len(dict(pairs)) == len(pairs), f"Duplicate keys in {path}"
    return dict(pairs)


def main():
    catalogs = {language: read_catalog(language) for language in ("zh-Hans", "en")}
    assert catalogs["zh-Hans"].keys() == catalogs["en"].keys(), "Language key sets differ"
    missing = source_keys() - catalogs["en"].keys()
    assert not missing, "Missing translations: " + repr(sorted(missing))
    for key in catalogs["en"]:
        placeholders = sorted(re.findall(r"\{\d+\}", key))
        for language, catalog in catalogs.items():
            assert catalog[key].strip(), f"Empty translation: {language}: {key}"
            assert sorted(re.findall(r"\{\d+\}", catalog[key])) == placeholders, (
                f"Interpolation mismatch: {language}: {key}"
            )
    print(f"localization ok: {len(catalogs['en'])} paired keys; all source keys covered")


if __name__ == "__main__":
    main()
