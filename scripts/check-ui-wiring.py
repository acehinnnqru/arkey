#!/usr/bin/env python3
"""List public engine names with no syntactic use in the owned Swift UI sources."""
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DECLARATION = re.compile(r"public (?:static )?(?:func|var|let) ([a-zA-Z_][a-zA-Z0-9_]*)")
STRING_START = re.compile(r'([#]*)("""|")')
USE = re.compile(r"\.\s*(\w+)\b|\b(\w+)\s*(?:\(|:)")


def swift_code(source):
    """Discard comments and string text, retaining code inside string interpolation."""
    def code(index, interpolation=False):
        result = []
        depth = 1
        while index < len(source):
            if source.startswith("//", index):
                end = source.find("\n", index)
                index = len(source) if end < 0 else end
                result.append(" ")
            elif source.startswith("/*", index):
                nesting = 1
                index += 2
                while index < len(source) and nesting:
                    if source.startswith("/*", index):
                        nesting += 1
                        index += 2
                    elif source.startswith("*/", index):
                        nesting -= 1
                        index += 2
                    else:
                        index += 1
                result.append(" ")
            elif match := STRING_START.match(source, index):
                literal_code, index = string(match)
                # A literal must not join tokens on either side of it.
                result.extend((" ; ", literal_code, " ; "))
            else:
                character = source[index]
                index += 1
                if interpolation:
                    depth += (character == "(") - (character == ")")
                    if depth == 0:
                        return "".join(result), index
                result.append(character)
        return "".join(result), index

    def string(match):
        hashes, quote = match.groups()
        closing = quote + hashes
        escape = "\\" + hashes
        index = match.end()
        result = []
        while index < len(source):
            if source.startswith(closing, index):
                return "".join(result), index + len(closing)
            if source.startswith(escape + "(", index):
                expression, index = code(index + len(escape) + 1, interpolation=True)
                result.extend((" ; ", expression, " ; "))
            elif source.startswith(escape, index):
                index += len(escape) + 1
            else:
                index += 1
        return "".join(result), index

    return code(0)[0]


def used_names(source):
    return {first or second for first, second in USE.findall(swift_code(source))}


def unused_names(root):
    declarations = set()
    for path in (root / "Packages/RimeEngine/Sources/RimeEngine").rglob("*.swift"):
        declarations.update(DECLARATION.findall(path.read_text()))
    used = set()
    for directory in ("arkey", "ARKeyboard", "KeyboardUI"):
        for path in (root / directory).rglob("*.swift"):
            used.update(used_names(path.read_text()))
    return sorted(declarations - used)


if __name__ == "__main__":
    print("\n".join(unused_names(ROOT)))
