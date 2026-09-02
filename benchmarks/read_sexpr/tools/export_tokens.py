#!/usr/bin/env python3
"""Export the read_sexpr corpus: the real token stream src/read.tl reads.

The compiler's reader (`src/read.tl`) never sees source bytes. It sees the
`(__tl_dyn-array token.Token)` array that `src/lex.tl` produced, and drives its
recursive descent off `token.tag-ref` plus one payload accessor per variant.
This tool reproduces that array for four compiler modules.

The byte-class tokenizer below is the same one
`benchmarks/intern_table/tools/export_idents.py` ports from `src/lex.tl`,
extended from "yield the Sym lexemes" to "emit every token", with:

  * `tag` = the integer `src/token.tl`'s `tag-*` constants return
    (LParen 1, RParen 2, Int 3, Sym 4, End 5, Str 6, Char 7, Float 8,
     LBracket 9, RBracket 10, Quote 11, Backtick 12, Comma 13, CommaAt 14),
  * `payload` = the integer the reader pulls out of the token:
      Sym   -> the intern id `ci.intern-source-slice-id` assigns to the raw
               source slice, by first occurrence over the whole stream,
      Str   -> the intern id of the UNESCAPED literal text; `src/lex.tl`
               interns string literals through the same
               `ci.intern-source-slice-id` entry point as symbols, so both
               share one pool here exactly as they do in the compiler,
      Int   -> `number-int-value`: `string.>int` of the decimal slice, or
               `parse-prefixed-int` for `0x`/`0X`/`0b`/`0B`, wrapped to 64
               signed bits,
      Char  -> the code point `apostrophe-char-literal-result` produces,
      Float -> an id assigned by first occurrence of the literal text
               (`Sexpr.Float` carries a `String`, not an intern id, so this is
               a separate id space),
      every delimiter, prefix token and `End` -> 0.

Each source file is lexed on its own and terminated with its `End` token,
exactly as `lex.result` does, and the four streams are concatenated. The reader
kernel recovers the four file boundaries by scanning for the `End` tags.

Layout of data/tokens.txt:

    # benchmarks/read_sexpr corpus v1
    # sources: ...
    # <statistics, all `#` comments>
    ntokens nfiles
    tag payload            (ntokens lines)

`#` starts a comment that runs to the end of its line, and the file is
whitespace-separated decimal integers otherwise, so both kernels read it with
the shared `cfg-scan-ints` scanner.

Regenerate from the repository root with:

    python3 benchmarks/read_sexpr/tools/export_tokens.py

which rewrites benchmarks/read_sexpr/data/tokens.txt. Deterministic: the same
sources always produce the same file.
"""

import os
import sys

# The same modules benchmarks/lex_source and benchmarks/intern_table use.
SOURCES = [
    "src/lex.tl",
    "src/compiler_liveness.tl",
    "src/compiler_symbols.tl",
    "src/compiler_lower.tl",
]

OUTPUT = "benchmarks/read_sexpr/data/tokens.txt"

TAG_LPAREN = 1
TAG_RPAREN = 2
TAG_INT = 3
TAG_SYM = 4
TAG_END = 5
TAG_STR = 6
TAG_CHAR = 7
TAG_FLOAT = 8
TAG_LBRACKET = 9
TAG_RBRACKET = 10
TAG_QUOTE = 11
TAG_BACKTICK = 12
TAG_COMMA = 13
TAG_COMMA_AT = 14

TAG_NAMES = {
    TAG_LPAREN: "LParen",
    TAG_RPAREN: "RParen",
    TAG_INT: "Int",
    TAG_SYM: "Sym",
    TAG_END: "End",
    TAG_STR: "Str",
    TAG_CHAR: "Char",
    TAG_FLOAT: "Float",
    TAG_LBRACKET: "LBracket",
    TAG_RBRACKET: "RBracket",
    TAG_QUOTE: "Quote",
    TAG_BACKTICK: "Backtick",
    TAG_COMMA: "Comma",
    TAG_COMMA_AT: "CommaAt",
}

MASK64 = (1 << 64) - 1


def wrap64(value):
    value &= MASK64
    return value - (1 << 64) if value >= (1 << 63) else value


# ---------------------------------------------------------------------------
# src/lex.tl byte classes and scanners.
# ---------------------------------------------------------------------------


def is_digit(c):
    return 48 <= c <= 57


def is_hex_digit(c):
    return is_digit(c) or 97 <= c <= 102 or 65 <= c <= 70


def is_binary_digit(c):
    return c in (48, 49)


def hex_digit_value(c):
    if 48 <= c <= 57:
        return c - 48
    if 97 <= c <= 102:
        return 10 + (c - 97)
    if 65 <= c <= 70:
        return 10 + (c - 65)
    return 0


def is_space(c):
    return c in (32, 9, 10, 13)


def is_symbol_char(c):
    """src/lex.tl `is-symbol-char`."""
    folded = c | 32
    if 97 <= folded <= 122:
        return True
    if 48 <= c <= 57:
        return True
    if 42 <= c <= 63:
        return c != 44 and c != 59
    return c == 33 or 37 <= c <= 38 or c == 95


def symbol_slice_eq(buf, start, end, value):
    return end - start == len(value) and buf[start:end] == value


def scan_symbol_end(buf, start, n):
    """src/lex.tl `scan-symbol-end`."""
    j = start
    while j < n:
        c = buf[j]
        if not is_symbol_char(c):
            break
        if c == 58 and j > start and not symbol_slice_eq(buf, start, j, b"pkg"):
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
    if colon_symbol_head(buf, start) or symbol_slice_eq(buf, start, end, b":as"):
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


ESCAPES = {110: b"\n", 116: b"\t", 114: b"\r", 48: b"\0", 92: b"\\", 39: b"'",
           34: b'"'}


def unescape_string_literal(buf, start, end):
    """src/lex.tl `unescape-string-literal` (via `string-escape-piece`)."""
    out = bytearray()
    i = start
    while i < end:
        c = buf[i]
        if c == 92:
            if i + 1 < end:
                out += ESCAPES.get(buf[i + 1], bytes([buf[i + 1]]))
                i += 2
            else:
                out += b"\\"
                i += 1
        else:
            out.append(c)
            i += 1
    return bytes(out)


def scan_comment_end(buf, start, n):
    """src/lex.tl `scan-comment-end`."""
    j = start
    while j < n and buf[j] != 10:
        j += 1
    return j


CHAR_ESCAPES = {110: 10, 116: 9, 114: 13, 48: 0, 92: 92, 39: 39}


def apostrophe_char_literal(buf, i, n):
    """src/lex.tl `apostrophe-char-literal-result`: (code, end) or None."""
    if i + 1 >= n:
        return None
    payload = buf[i + 1]
    if payload == 92:
        esc = i + 2
        if esc >= n:
            raise ValueError("unterminated character literal")
        if buf[esc] not in CHAR_ESCAPES:
            raise ValueError("unknown character escape")
        if not (i + 3 < n and buf[i + 3] == 39):
            raise ValueError("expected ' after character")
        return (CHAR_ESCAPES[buf[esc]], i + 4)
    if payload in (39, 10, 13):
        return None
    if i + 2 < n and buf[i + 2] == 39:
        return (payload, i + 3)
    return None


def number_digits_start(buf, start):
    return start + 1 if buf[start] == 45 else start


def number_prefixed(buf, start, n):
    ds = number_digits_start(buf, start)
    if ds + 1 < n and buf[ds] == 48:
        return buf[ds + 1] in (120, 88, 98, 66)
    return False


def number_prefix_base(buf, start):
    return 16 if buf[number_digits_start(buf, start) + 1] in (120, 88) else 2


def scan_int_end(buf, start, n):
    j = start
    while j < n and is_digit(buf[j]):
        j += 1
    return j


def scan_based_int_end(buf, start, n, base):
    j = start
    while j < n:
        c = buf[j]
        if not (is_hex_digit(c) if base == 16 else is_binary_digit(c)):
            break
        j += 1
    return j


def float_tail(buf, int_end, n):
    return int_end + 1 < n and buf[int_end] == 46 and is_digit(buf[int_end + 1])


def scan_number_end(buf, start, n):
    """src/lex.tl `scan-number-end` (decimal, fraction, exponent)."""
    ds = number_digits_start(buf, start)
    int_end = scan_int_end(buf, ds, n)
    j = int_end
    if float_tail(buf, int_end, n):
        j = scan_int_end(buf, int_end + 1, n)
    if j < n and buf[j] in (101, 69):
        mark = j
        exp_digits = j + 1
        if exp_digits < n and buf[exp_digits] in (43, 45):
            exp_digits += 1
        if exp_digits < n and is_digit(buf[exp_digits]):
            j = scan_int_end(buf, exp_digits, n)
        else:
            j = mark
    return j


def scan_number_end_checked(buf, start, n):
    """src/lex.tl `scan-number-end-result`."""
    if number_prefixed(buf, start, n):
        ds = number_digits_start(buf, start)
        base = number_prefix_base(buf, start)
        value_start = ds + 2
        end = scan_based_int_end(buf, value_start, n, base)
        if end == value_start:
            raise ValueError("malformed integer literal")
        if end < n and is_symbol_char(buf[end]):
            raise ValueError("malformed integer literal")
        return end
    end = scan_number_end(buf, start, n)
    if end < n and (buf[end] in (101, 69) or is_symbol_char(buf[end])):
        raise ValueError("malformed number literal")
    return end


def number_is_float(buf, start, end, n):
    """src/lex.tl `number-float?`."""
    if number_prefixed(buf, start, n):
        return False
    i = number_digits_start(buf, start)
    while i < end:
        if buf[i] in (46, 101, 69):
            return True
        i += 1
    return False


def number_int_value(buf, start, end, n):
    """src/lex.tl `number-int-value`, wrapped to 64 signed bits."""
    if number_prefixed(buf, start, n):
        ds = number_digits_start(buf, start)
        base = number_prefix_base(buf, start)
        sign = -1 if buf[start] == 45 else 1
        value = 0
        j = ds + 2
        while j < end:
            value = wrap64(value * base + hex_digit_value(buf[j]))
            j += 1
        return wrap64(sign * value)
    # `string.>int` of the decimal slice: optional '-', then digit folding.
    j = start
    negative = buf[j] == 45
    if negative:
        j += 1
    value = 0
    while j < end and is_digit(buf[j]):
        value = wrap64(value * 10 + (buf[j] - 48))
        j += 1
    return wrap64(-value if negative else value)


def negative_number_start(buf, start, n):
    return buf[start] == 45 and start + 1 < n and is_digit(buf[start + 1])


# ---------------------------------------------------------------------------
# The token stream.
# ---------------------------------------------------------------------------


def lex_tokens(buf, intern, floats):
    """Yield `(tag, payload)` for every token src/lex.tl produces, without the
    trailing `End`. `intern` is the shared symbol/string-literal pool and
    `floats` the float-text pool; both are `dict` name -> id."""
    n = len(buf)
    i = 0
    while i < n:
        c = buf[i]
        if is_space(c):
            i += 1
        elif c == 40:
            yield (TAG_LPAREN, 0)
            i += 1
        elif c == 91:
            yield (TAG_LBRACKET, 0)
            i += 1
        elif c == 41:
            yield (TAG_RPAREN, 0)
            i += 1
        elif c == 93:
            yield (TAG_RBRACKET, 0)
            i += 1
        elif c == 39:
            literal = apostrophe_char_literal(buf, i, n)
            if literal is None:
                yield (TAG_QUOTE, 0)
                i += 1
            else:
                yield (TAG_CHAR, literal[0])
                i = literal[1]
        elif c == 96:
            yield (TAG_BACKTICK, 0)
            i += 1
        elif c == 44:
            if i + 1 < n and buf[i + 1] == 64:
                yield (TAG_COMMA_AT, 0)
                i += 2
            else:
                yield (TAG_COMMA, 0)
                i += 1
        elif c == 34:
            start = i + 1
            end = scan_str_end(buf, start, n)
            text = unescape_string_literal(buf, start, end)
            yield (TAG_STR, intern.setdefault(text, len(intern)))
            i = end + 1
        elif c == 59:
            i = scan_comment_end(buf, i + 1, n)
        elif is_digit(c) or negative_number_start(buf, i, n):
            end = scan_number_end_checked(buf, i, n)
            if number_is_float(buf, i, end, n):
                text = buf[i:end]
                yield (TAG_FLOAT, floats.setdefault(text, len(floats)))
            else:
                yield (TAG_INT, number_int_value(buf, i, end, n))
            i = end
        elif c == 58:
            end = colon_token_end(buf, i, n)
            if end > i + 1:
                yield (TAG_SYM, intern.setdefault(buf[i:end], len(intern)))
                i = end
            else:
                yield (TAG_SYM, intern.setdefault(b":", len(intern)))
                i += 1
        elif is_symbol_char(c):
            end = scan_symbol_end(buf, i, n)
            yield (TAG_SYM, intern.setdefault(buf[i:end], len(intern)))
            i = end
        else:
            raise ValueError("lexer: unexpected character %d at %d" % (c, i))


# ---------------------------------------------------------------------------
# src/read.tl's recursive descent, replayed to count what the kernel must find.
# ---------------------------------------------------------------------------


class Reader(object):
    """`form-result` / `list-result-with-close` over one file's tokens.

    Counts exactly the `sexpr-node-push` calls the compiler's reader makes:
    one per element copied out of a builder by `sexpr-list-from-builder`.
    """

    def __init__(self, tokens, start):
        self.tokens = tokens
        self.pos = start
        self.nodes = 0
        self.max_depth = 0
        self.lists = 0
        # Recursive `sexpr-walk` calls the consumer makes: one per atom, and
        # one Cons step per element plus one Nil step per list.
        self.walk_calls = 0

    def form(self, depth):
        if depth > self.max_depth:
            self.max_depth = depth
        tag = self.tokens[self.pos][0]
        if tag in (TAG_INT, TAG_FLOAT, TAG_SYM, TAG_STR, TAG_CHAR):
            self.pos += 1
            self.walk_calls += 1
            return
        if tag == TAG_LPAREN:
            self.pos += 1
            self.list_with_close(TAG_RPAREN, depth)
            return
        if tag == TAG_LBRACKET:
            self.pos += 1
            self.list_with_close(TAG_RBRACKET, depth)
            return
        if tag in (TAG_QUOTE, TAG_BACKTICK, TAG_COMMA, TAG_COMMA_AT):
            self.pos += 1
            self.form(depth + 1)
            # `prefix-form` seals a two-element list: the prefix symbol and the
            # wrapped form.
            self.nodes += 2
            self.lists += 1
            self.walk_calls += 4
            return
        raise ValueError("reader: unexpected token tag %d" % tag)

    def list_with_close(self, close_tag, depth):
        count = 0
        while True:
            tag = self.tokens[self.pos][0]
            if tag == close_tag:
                self.pos += 1
                self.nodes += count
                self.lists += 1
                self.walk_calls += count + 1
                return
            if tag == TAG_END:
                raise ValueError("reader: unterminated list")
            self.form(depth + 1)
            count += 1


def replay_reader(tokens, starts):
    """Drive the reader over every file the way the loader does: one top-level
    form at a time, resetting the node pool before each."""
    forms = 0
    nodes = 0
    lists = 0
    max_depth = 0
    peak_pool = 0
    walk_calls = 0
    for start in starts:
        reader = Reader(tokens, start)
        while tokens[reader.pos][0] != TAG_END:
            before = reader.nodes
            reader.form(0)
            forms += 1
            peak_pool = max(peak_pool, reader.nodes - before)
        nodes += reader.nodes
        lists += reader.lists
        walk_calls += reader.walk_calls
        max_depth = max(max_depth, reader.max_depth)
    return forms, nodes, lists, max_depth, peak_pool, walk_calls


def recount(path):
    """Independent second count: re-read the written corpus and recover the
    token count and file count from the records themselves."""
    with open(path, "rb") as handle:
        blob = handle.read()
    values = []
    for raw in blob.split(b"\n"):
        line = raw.split(b"#", 1)[0]
        values.extend(int(piece) for piece in line.split())
    header_tokens = values[0]
    header_files = values[1]
    pairs = (len(values) - 2) // 2
    ends = sum(1 for k in range(pairs) if values[2 + 2 * k] == TAG_END)
    balance = {TAG_LPAREN: 0, TAG_RPAREN: 0, TAG_LBRACKET: 0, TAG_RBRACKET: 0}
    for k in range(pairs):
        tag = values[2 + 2 * k]
        if tag in balance:
            balance[tag] += 1
    return header_tokens, header_files, pairs, ends, balance


def main(argv):
    root = argv[1] if len(argv) > 1 else "."
    out_path = os.path.join(root, OUTPUT)
    os.makedirs(os.path.dirname(out_path), exist_ok=True)

    intern = {}
    floats = {}
    tokens = []
    starts = []
    per_file = []
    for name in SOURCES:
        with open(os.path.join(root, name), "rb") as handle:
            data = handle.read()
        starts.append(len(tokens))
        before = len(tokens)
        for record in lex_tokens(data, intern, floats):
            tokens.append(record)
        tokens.append((TAG_END, 0))
        per_file.append((name, len(data), len(tokens) - before))

    (forms, nodes, lists, max_depth, peak_pool,
     walk_calls) = replay_reader(tokens, starts)

    histogram = {}
    for tag, _ in tokens:
        histogram[tag] = histogram.get(tag, 0) + 1
    mix = "  ".join(
        "%s %d" % (TAG_NAMES[tag], histogram[tag]) for tag in sorted(histogram))

    out = []
    out.append(b"# benchmarks/read_sexpr corpus v1\n")
    out.append(b"# sources: " + b" ".join(s.encode() for s in SOURCES) + b"\n")
    out.append(b"# the token stream src/lex.tl produces for each module, each\n")
    out.append(b"# file terminated by its own End token (tag 5).\n")
    out.append(b"# tags: LParen 1 RParen 2 Int 3 Sym 4 End 5 Str 6 Char 7\n")
    out.append(b"#       Float 8 LBracket 9 RBracket 10 Quote 11 Backtick 12\n")
    out.append(b"#       Comma 13 CommaAt 14\n")
    for name, size, count in per_file:
        out.append(("# %s: %d bytes, %d tokens\n" % (name, size, count)).encode())
    out.append(("# tokens %d  files %d  distinct-interned %d  distinct-floats %d\n"
                % (len(tokens), len(SOURCES), len(intern), len(floats))).encode())
    out.append(("# top-level forms %d  nodes %d  lists %d  max-depth %d\n"
                % (forms, nodes, lists, max_depth)).encode())
    out.append(("# peak nodes in one top-level form %d  walk calls %d\n"
                % (peak_pool, walk_calls)).encode())
    out.append(("# atom mix: %s\n" % mix).encode())
    out.append(b"# format: ntokens nfiles, then `tag payload` per token\n")
    out.append(("%d %d\n" % (len(tokens), len(SOURCES))).encode())
    for tag, payload in tokens:
        out.append(("%d %d\n" % (tag, payload)).encode())
    blob = b"".join(out)
    with open(out_path, "wb") as handle:
        handle.write(blob)

    header_tokens, header_files, pairs, ends, balance = recount(out_path)
    ok = (header_tokens == len(tokens) and header_files == len(SOURCES)
          and pairs == len(tokens) and ends == len(SOURCES)
          and balance[TAG_LPAREN] == balance[TAG_RPAREN]
          and balance[TAG_LBRACKET] == balance[TAG_RBRACKET])

    print("wrote %s: %d bytes" % (OUTPUT, len(blob)))
    for name, size, count in per_file:
        print("  %-28s %8d bytes  %7d tokens" % (name, size, count))
    print("  tokens: %d  files: %d  interned: %d  float texts: %d"
          % (len(tokens), len(SOURCES), len(intern), len(floats)))
    print("  top-level forms: %d  nodes: %d  lists: %d  max depth: %d"
          % (forms, nodes, lists, max_depth))
    print("  peak nodes in one top-level form: %d  walk calls: %d"
          % (peak_pool, walk_calls))
    print("  atom mix: %s" % mix)
    print("  independent recount: tokens %d  End tokens %d  "
          "( ) %d/%d  [ ] %d/%d  -> %s"
          % (pairs, ends, balance[TAG_LPAREN], balance[TAG_RPAREN],
             balance[TAG_LBRACKET], balance[TAG_RBRACKET],
             "ok" if ok else "MISMATCH"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
