#!/usr/bin/env python3
"""Static SwiftUI identifier coverage, unique source templates and BCR physical bindings."""

from __future__ import annotations

import json
import re
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
KINDS = r"Button|Toggle|Picker|Slider|TextField|SecureField|TextEditor|Stepper|Menu|DisclosureGroup|SettingsLink|OffscreenSafeMenu"


def mask(source):
    result = list(source)

    def blank(a, b):
        for i in range(a, b):
            if result[i] != "\n":
                result[i] = " "

    def string(at):
        start = at
        while at < len(source) and source[at] == "#":
            at += 1
        hashes = at - start
        quote = '"""' if source.startswith('"""', at) else '"'
        at += len(quote)
        close = quote + "#" * hashes
        while at < len(source):
            if source.startswith(close, at):
                return at + len(close)
            escape = "\\" + "#" * hashes
            if source.startswith(escape, at):
                at += len(escape)
                if at < len(source) and source[at] == "(":
                    at = interpolation(at)
                else:
                    at += 1
            else:
                at += 1
        return at

    def interpolation(at):
        depth = 1
        at += 1
        while at < len(source) and depth:
            if source[at] == '"' or (source[at] == "#" and re.match(r'#+"', source[at:])):
                at = string(at)
            elif source[at] == "(":
                depth += 1
                at += 1
            elif source[at] == ")":
                depth -= 1
                at += 1
            else:
                at += 1
        return at

    at = 0
    while at < len(source):
        start = at
        if source.startswith("//", at):
            at = source.find("\n", at)
            if at < 0:
                at = len(source)
        elif source.startswith("/*", at):
            depth = 1
            at += 2
            while at < len(source) and depth:
                if source.startswith("/*", at):
                    depth += 1
                    at += 2
                elif source.startswith("*/", at):
                    depth -= 1
                    at += 2
                else:
                    at += 1
        elif source[at] == '"' or (source[at] == "#" and re.match(r'#+"', source[at:])):
            at = string(at)
        else:
            at += 1
            continue
        blank(start, at)
    return "".join(result)


def balanced(code, at):
    pairs = {"(": ")", "[": "]", "{": "}"}
    stack = [pairs[code[at]]]
    at += 1
    while at < len(code) and stack:
        if code[at] in pairs:
            stack.append(pairs[code[at]])
        elif code[at] == stack[-1]:
            stack.pop()
        at += 1
    return at


def skip(code, at):
    while at < len(code) and code[at].isspace():
        at += 1
    return at


def invocation_end(code, at):
    at = skip(code, at)
    if at < len(code) and code[at] == "(":
        at = skip(code, balanced(code, at))
    if at < len(code) and code[at] == "{":
        at = balanced(code, at)
    while match := re.match(r"\s*\w+\s*:\s*(?=\{)", code[at:]):
        at = balanced(code, at + match.end())
    return at


def controls(source):
    code = mask(source)
    rows = []
    for match in re.finditer(r"\b(" + KINDS + r")\s*(?=[({])", code):
        end = invocation_end(code, match.end())
        at = end
        modifiers = []
        while modifier := re.match(r"\s*\.\s*(\w+)\s*(?=[({])", code[at:]):
            modifiers.append(modifier[1])
            at = invocation_end(code, at + modifier.end())
        rows.append({"kind": match[1], "start": match.start(), "end": end, "modifiers": modifiers})
    return rows


def check(root=ROOT):
    missing, duplicates, templates = [], [], {}
    count = 0
    for path in sorted((root / "Sources/BCRAgentConsole").rglob("*.swift")):
        source = path.read_text()
        code = mask(source)
        for row in controls(source):
            count += 1
            if "accessibilityIdentifier" not in row["modifiers"]:
                missing.append(f"{path.name}:{source.count(chr(10), 0, row['start']) + 1}: {row['kind']}")
        for match in re.finditer(r'\.accessibilityIdentifier\("((?:[^"\\]|\\.)*)"\)', source):
            if code[match.start()] != ".":
                continue
            identifier = match[1]
            if identifier in templates:
                duplicates.append(identifier)
            templates[identifier] = path.name
    panel = (root / "Sources/BCRAgentConsole/SurfacePanelView.swift").read_text()
    for family in ("UserKeyCell", "KnobCell", "PadCell", "PushButtonCell"):
        start = panel.find("private struct " + family + ":")
        end = panel.find("private struct ", start + 1)
        body = panel[start : end if end >= 0 else len(panel)] if start >= 0 else ""
        if body.count(".accessibilityIdentifier(presentation.control.accessibilityID)") != 1:
            missing.append("Panel binding " + family)
    return {"controls": count, "identifier_templates": len(templates), "missing": missing, "duplicates": duplicates}


def main():
    result = check()
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return int(bool(result["missing"] or result["duplicates"]))


if __name__ == "__main__":
    raise SystemExit(main())
