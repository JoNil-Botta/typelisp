#!/usr/bin/env python3
"""Export the intern_table corpus: the real identifier stream the compiler's
interner sees, in encounter order.

The interner behind the `intern.slice_misses` compile-profile counter is fed by
src/lex.tl, which calls `ci.intern-source-slice` once per `Token.Sym` lexeme as
it walks a source file. This tool reproduces that stream: it runs the same
byte-class tokenizer the lexer runs (the classifier ported from src/lex.tl, the
same one benchmarks/lex_source implements) over the same corpus modules, and
writes every symbol lexeme, one per line, in the order the lexer produced it.
Encounter order is what matters: it is what gives the interner its true
first-occurrence-miss / repeat-hit ratio, its collision families (the compiler's
sources are full of names sharing long dashed prefixes), and its load curve.

String-literal interning (`Token.Str`, which also calls `intern-source-slice`)
is excluded so the corpus stays line oriented; symbol lexemes never contain
whitespace.

Regenerate from the repository root with:

    python3 benchmarks/intern_table/tools/export_idents.py

which rewrites benchmarks/intern_table/data/idents.txt. Deterministic: the same
sources always produce the same stream.
"""

import os
import sys

# The same modules benchmarks/lex_source/tools/export_corpus.py concatenates.
SOURCES = [
    "src/lex.tl",
    "src/compiler_liveness.tl",
    "src/compiler_symbols.tl",
    "src/compiler_lower.tl",
]

OUTPUT = "benchmarks/intern_table/data/idents.txt"


def is_digit(c):
    return 48 <= c <= 57


def is_space(c):
    return c in (32, 9, 10, 13)


def is_symbol_char(c):
    """src/lex.tl `is-symbol-char`."""
    if 97 <= c <= 122:
        return True
    if 65 <= c <= 90:
        return True
    if 48 <= c <= 57:
        return True
    if c == 45:
        return True
    if c == 95:
        return True
    if c == 33:
        return True
    if 37 <= c <= 38:
        return True
    if c == 42:
        return True
    if c == 43:
        return True
    if c == 46:
        return True
    if c == 47:
        return True
    if c == 58:
        return True
    if 60 <= c <= 63:
        return True
    return False


def slice_pkg(buf, start, end):
    return end - start == 3 and buf[start:end] == b"pkg"


def slice_colon_as(buf, start, end):
    return end - start == 3 and buf[start:end] == b":as"


def scan_symbol_end(buf, start, n):
    """src/lex.tl `scan-symbol-end`."""
    j = start
    while j < n:
        c = buf[j]
        if c == 58 and j > start and not slice_pkg(buf, start, j):
            break
        if not is_symbol_char(c):
            break
        j += 1
    return j


def colon_symbol_head(buf, start):
    """src/lex.tl `colon-symbol-head?`."""
    j = start - 1
    while j >= 0:
        c = buf[j]
        if is_space(c):
            j -= 1
            continue
        return c == 40
    return True


def colon_token_end(buf, start, n):
    """src/lex.tl `colon-token-end`."""
    end = scan_symbol_end(buf, start, n)
    if colon_symbol_head(buf, start) or slice_colon_as(buf, start, end):
        return end
    return start + 1


def scan_str_end(buf, start, n):
    """src/lex.tl `scan-str-end-result`."""
    j = start
    while j < n:
        c = buf[j]
        if c == 34:
            return j
        if c == 92:
            if j + 1 < n:
                j += 2
                continue
            return j
        j += 1
    return j


def scan_comment_end(buf, start, n):
    j = start
    while j < n and buf[j] != 10:
        j += 1
    return j


def apostrophe_char_end(buf, i, n):
    """src/lex.tl `apostrophe-char-literal-result`, as an end index or -1."""
    if i + 1 >= n:
        return -1
    payload = buf[i + 1]
    if payload == 92:
        esc = i + 2
        if esc >= n:
            return -1
        if buf[esc] in (110, 116, 114, 48, 92, 39):
            if i + 3 < n and buf[i + 3] == 39:
                return i + 4
            return -1
        return -1
    if payload in (39, 10, 13):
        return -1
    if i + 2 < n and buf[i + 2] == 39:
        return i + 3
    return -1


def number_digits_start(buf, start):
    return start + 1 if buf[start] == 45 else start


def number_prefixed(buf, start, n):
    ds = number_digits_start(buf, start)
    if ds + 1 < n and buf[ds] == 48:
        return buf[ds + 1] in (120, 88, 98, 66)
    return False


def scan_int_end(buf, start, n):
    j = start
    while j < n and is_digit(buf[j]):
        j += 1
    return j


def float_tail(buf, int_end, n):
    return int_end + 1 < n and buf[int_end] == 46 and is_digit(buf[int_end + 1])


def scan_number_end(buf, start, n):
    if number_prefixed(buf, start, n):
        ds = number_digits_start(buf, start)
        base16 = buf[ds + 1] in (120, 88)
        j = ds + 2
        while j < n:
            c = buf[j]
            if base16:
                ok = is_digit(c) or 97 <= c <= 102 or 65 <= c <= 70
            else:
                ok = c in (48, 49)
            if not ok:
                break
            j += 1
        return j
    ds = number_digits_start(buf, start)
    int_end = scan_int_end(buf, ds, n)
    if float_tail(buf, int_end, n):
        return scan_int_end(buf, int_end + 1, n)
    return int_end


def negative_number_start(buf, start, n):
    return buf[start] == 45 and start + 1 < n and is_digit(buf[start + 1])


def symbol_lexemes(buf):
    """Yield every `Token.Sym` lexeme, in the order src/lex.tl produces it."""
    n = len(buf)
    i = 0
    while i < n:
        c = buf[i]
        if is_space(c):
            i += 1
        elif c in (40, 91, 41, 93, 96):
            i += 1
        elif c == 39:
            end = apostrophe_char_end(buf, i, n)
            i = i + 1 if end < 0 else end
        elif c == 44:
            i += 2 if (i + 1 < n and buf[i + 1] == 64) else 1
        elif c == 34:
            i = scan_str_end(buf, i + 1, n) + 1
        elif c == 59:
            i = scan_comment_end(buf, i + 1, n)
        elif is_digit(c) or negative_number_start(buf, i, n):
            i = scan_number_end(buf, i, n)
        elif c == 58:
            end = colon_token_end(buf, i, n)
            yield buf[i:end]
            i = end
        elif is_symbol_char(c):
            end = scan_symbol_end(buf, i, n)
            yield buf[i:end]
            i = end
        else:
            i += 1


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    out_path = os.path.join(root, OUTPUT)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    total = 0
    distinct = set()
    lines = []
    for name in SOURCES:
        with open(os.path.join(root, name), "rb") as handle:
            data = handle.read()
        for lexeme in symbol_lexemes(data):
            lines.append(lexeme)
            distinct.add(lexeme)
            total += 1

    blob = b"\n".join(lines) + b"\n"
    with open(out_path, "wb") as handle:
        handle.write(blob)

    print("wrote %s: %d bytes" % (OUTPUT, len(blob)))
    print("  identifiers: %d  distinct: %d  hit rate: %.4f"
          % (total, len(distinct), 1.0 - (float(len(distinct)) / float(total))))
    lengths = sorted(len(x) for x in lines)
    print("  length min/median/p90/max: %d/%d/%d/%d"
          % (lengths[0], lengths[len(lengths) // 2],
             lengths[(len(lengths) * 9) // 10], lengths[-1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
