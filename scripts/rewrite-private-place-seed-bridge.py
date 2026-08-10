#!/usr/bin/env python3
"""Rewrite private place bridge calls to the legacy seed source forms.

This operates only on a temporary bootstrap mirror.  It is deliberately a
small source-aware scanner rather than a regular expression: projection targets
are arbitrary nested s-expressions and field-name bridge calls carry the field
as a string literal.
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass
from pathlib import Path


NAMES = {
    "__tl-project-field",
    "__tl-project-set-field",
    "__tl-project-field-name",
    "__tl-project-set-field-name",
    "__tl-box-place",
}


@dataclass(frozen=True)
class Call:
    start: int
    end: int
    name: str
    args: tuple[tuple[int, int], ...]


def skip_trivia(text: str, pos: int) -> int:
    n = len(text)
    while pos < n:
        if text[pos].isspace():
            pos += 1
            continue
        if text[pos] == ";":
            newline = text.find("\n", pos)
            return n if newline < 0 else skip_trivia(text, newline + 1)
        return pos
    return pos


def string_end(text: str, pos: int) -> int:
    start = pos
    pos += 1
    while pos < len(text):
        if text[pos] == "\\":
            pos += 2
        elif text[pos] == '"':
            return pos + 1
        else:
            pos += 1
    raise ValueError(f"unterminated string literal at offset {start}")


def char_literal_end(text: str, pos: int) -> int | None:
    if pos >= len(text) or text[pos] != "'":
        return None
    if pos + 2 < len(text) and text[pos + 1] != "\\" and text[pos + 2] == "'":
        return pos + 3
    if pos + 3 < len(text) and text[pos + 1] == "\\" and text[pos + 3] == "'":
        return pos + 4
    return None


def expr_end(text: str, pos: int) -> int:
    pos = skip_trivia(text, pos)
    if pos >= len(text):
        raise ValueError("missing expression")
    ch = text[pos]
    if ch == '"':
        return string_end(text, pos)
    char_end = char_literal_end(text, pos)
    if char_end is not None:
        return char_end
    if ch in "([":
        close = ")" if ch == "(" else "]"
        depth = 1
        cursor = pos + 1
        while cursor < len(text):
            nested_char_end = char_literal_end(text, cursor)
            if nested_char_end is not None:
                cursor = nested_char_end
            elif text[cursor] == '"':
                cursor = string_end(text, cursor)
            elif text[cursor] == ";":
                newline = text.find("\n", cursor)
                cursor = len(text) if newline < 0 else newline + 1
            elif text[cursor] == ch:
                depth += 1
                cursor += 1
            elif text[cursor] == close:
                depth -= 1
                cursor += 1
                if depth == 0:
                    return cursor
            elif text[cursor] in "([":
                cursor = expr_end(text, cursor)
            else:
                cursor += 1
        raise ValueError(f"unterminated {ch} expression")
    if ch in "'`":
        return expr_end(text, pos + 1)
    if ch == ",":
        return expr_end(text, pos + (2 if text.startswith(",@", pos) else 1))
    cursor = pos
    while cursor < len(text):
        if text[cursor].isspace() or text[cursor] in "()[];":
            break
        cursor += 1
    if cursor == pos:
        raise ValueError(f"invalid expression at offset {pos}")
    return cursor


def symbol_end(text: str, pos: int) -> int:
    cursor = pos
    while cursor < len(text):
        if text[cursor].isspace() or text[cursor] in "()[];\"":
            break
        cursor += 1
    return cursor


def find_calls(text: str) -> list[Call]:
    calls: list[Call] = []
    pos = 0
    while pos < len(text):
        literal_end = char_literal_end(text, pos)
        if literal_end is not None:
            pos = literal_end
            continue
        if text[pos] == '"':
            pos = string_end(text, pos)
            continue
        if text[pos] == ";":
            newline = text.find("\n", pos)
            pos = len(text) if newline < 0 else newline + 1
            continue
        if text[pos] != "(":
            pos += 1
            continue
        head_start = skip_trivia(text, pos + 1)
        head_end = symbol_end(text, head_start)
        name = text[head_start:head_end]
        if name not in NAMES:
            pos += 1
            continue
        expected = 1 if name == "__tl-box-place" else 3 if "set-field" in name else 2
        args: list[tuple[int, int]] = []
        cursor = head_end
        for _ in range(expected):
            start = skip_trivia(text, cursor)
            end = expr_end(text, start)
            args.append((start, end))
            cursor = end
        cursor = skip_trivia(text, cursor)
        if cursor >= len(text) or text[cursor] != ")":
            raise ValueError(f"{name} has unexpected arity at offset {pos}")
        calls.append(Call(pos, cursor + 1, name, tuple(args)))
        pos += 1
    return calls


def field_text(text: str, span: tuple[int, int], string_name: bool) -> str:
    raw = text[span[0] : span[1]]
    if not string_name:
        return raw
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ValueError(f"invalid field string {raw!r}") from exc
    if not isinstance(value, str) or not value or any(
        ch.isspace() or ch in "()[]{}\"';`," for ch in value
    ):
        raise ValueError(f"field string is not a source identifier: {raw!r}")
    return value


def replacement(text: str, call: Call) -> str:
    args = [text[start:end] for start, end in call.args]
    if call.name == "__tl-box-place":
        return f"(box-get {args[0]})"
    string_name = call.name.endswith("-field-name")
    field = field_text(text, call.args[1], string_name)
    if "set-field" in call.name:
        return f"(set! (struct-get {args[0]} {field}) {args[2]})"
    return f"(struct-get {args[0]} {field})"


def rewrite(text: str) -> tuple[str, int]:
    count = 0
    while True:
        calls = find_calls(text)
        if not calls:
            return text, count
        innermost = [
            call
            for call in calls
            if not any(call.start < other.start and other.end < call.end for other in calls)
        ]
        if not innermost:
            raise ValueError("private place bridge rewrite made no progress")
        for call in sorted(innermost, key=lambda item: item.start, reverse=True):
            text = text[: call.start] + replacement(text, call) + text[call.end :]
            count += 1


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(f"usage: {argv[0]} root [root ...]", file=sys.stderr)
        return 2
    total = 0
    for root_text in argv[1:]:
        root = Path(root_text)
        for path in sorted(root.rglob("*.tl")):
            if path.as_posix().endswith("/stdlib/core_macros.tl"):
                continue
            original = path.read_text(encoding="utf-8")
            try:
                rewritten, count = rewrite(original)
            except ValueError as exc:
                raise ValueError(f"{path}: {exc}") from exc
            if count:
                path.write_text(rewritten, encoding="utf-8", newline="")
                total += count
    print(f"private place seed bridge rewrote {total} call(s)")
    if total == 0:
        print("private place seed bridge found no calls", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
