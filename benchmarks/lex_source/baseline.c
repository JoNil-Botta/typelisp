/* benchmarks/lex_source/baseline.c - clang C baseline for lex_source.
 *
 * Equivalent to benchmarks/lex_source/bench.tl: the byte-class dispatch of the
 * self-hosting compiler's lexer, run over REAL compiler source text. The corpus
 * in benchmarks/lex_source/data/corpus.tl-txt is a byte-for-byte concatenation
 * of src/lex.tl, src/compiler_liveness.tl, src/compiler_symbols.tl and
 * src/compiler_lower.tl, produced by
 * benchmarks/lex_source/tools/export_corpus.py.
 *
 * The classifier, the scanners, the token-kind numbering, and the line/column
 * tracking mirror src/lex.tl `lex-into-spanned-tokens-result` and its helpers
 * (`is-space`, `is-digit`, `is-hex-digit`, `is-binary-digit`, `is-symbol-char`,
 * `scan-int-end`, `scan-based-int-end`, `float-tail?`, `number-digits-start`,
 * `number-prefixed?`, `number-prefix-base`, `scan-number-end`, `number-float?`,
 * `negative-number-start?`, `scan-symbol-end` with its `pkg` slice exception,
 * `colon-symbol-head?`, `colon-token-end`, `scan-str-end-result`,
 * `scan-comment-end`, `apostrophe-char-literal-result`,
 * `apostrophe-escaped-char-result`, `lex-advance-position`) together with the
 * kind tags of src/token.tl `tag`.
 *
 * The corpus is loaded once and tokenized `rounds` times. Every token folds its
 * (kind, length, first byte) into a wrapping 64-bit accumulator; after each
 * pass the final line, column, and token count fold in too. TypeLisp `+`/`-`/
 * `*` wrap modulo 2^64, so the accumulator is formed in uint64_t here and the
 * printed decimal matches TypeLisp's print of an i64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* Token-kind tags, kept in the numbering of src/token.tl `tag`. */
#define LS_TAG_LPAREN 1
#define LS_TAG_RPAREN 2
#define LS_TAG_INT 3
#define LS_TAG_SYM 4
#define LS_TAG_STR 6
#define LS_TAG_CHAR 7
#define LS_TAG_FLOAT 8
#define LS_TAG_LBRACKET 9
#define LS_TAG_RBRACKET 10
#define LS_TAG_QUOTE 11
#define LS_TAG_BACKTICK 12
#define LS_TAG_COMMA 13
#define LS_TAG_COMMA_AT 14

/* Contribution of a byte no arm of the dispatch accepts. In the compiler this
 * is the recoverable "lexer: unexpected character" diagnostic; here it keeps
 * the dispatch's shape and absorbs any non-ASCII byte outside a literal. */
#define LS_TAG_UNEXPECTED 99

/* ---- byte classifiers (src/lex.tl) ---- */
static int ls_digit(int64_t c) { return c >= 48 && c <= 57; }

static int ls_hex_digit(int64_t c) {
    return ls_digit(c) || (c >= 97 && c <= 102) || (c >= 65 && c <= 70);
}

static int ls_binary_digit(int64_t c) { return c == 48 || c == 49; }

/* `is-symbol-char`: a letter, a digit, or one of the symbol-punctuation codes. */
static int ls_symbol_char(int64_t c) {
    if (c >= 97 && c <= 122) {
        return 1;
    }
    if (c >= 65 && c <= 90) {
        return 1;
    }
    if (c >= 48 && c <= 57) {
        return 1;
    }
    if (c == 45) {
        return 1;
    }
    if (c == 95) {
        return 1;
    }
    if (c == 33) {
        return 1;
    }
    if (c >= 37 && c <= 38) {
        return 1;
    }
    if (c == 42) {
        return 1;
    }
    if (c == 43) {
        return 1;
    }
    if (c == 46) {
        return 1;
    }
    if (c == 47) {
        return 1;
    }
    if (c == 58) {
        return 1;
    }
    if (c >= 60 && c <= 63) {
        return 1;
    }
    return 0;
}

static int ls_space(int64_t c) {
    return c == 32 || c == 9 || c == 10 || c == 13;
}

static int64_t ls_byte(const unsigned char *buf, int64_t index) {
    return (int64_t)buf[index];
}

/* ---- scanners (src/lex.tl) ---- */
/* `scan-int-end`: the digit run starting at `start`. The bounds check is kept
 * outside the element read, matching the lexer's discipline. */
static int64_t ls_scan_int_end(const unsigned char *buf, int64_t start,
                               int64_t n) {
    int64_t j = start;
    int keep = 1;
    while (keep) {
        if (j < n) {
            if (ls_digit(ls_byte(buf, j))) {
                j = j + 1;
            } else {
                keep = 0;
            }
        } else {
            keep = 0;
        }
    }
    return j;
}

static int64_t ls_scan_based_int_end(const unsigned char *buf, int64_t start,
                                     int64_t n, int64_t base) {
    int64_t j = start;
    int keep = 1;
    while (keep) {
        if (j < n) {
            int64_t c = ls_byte(buf, j);
            if (base == 16 ? ls_hex_digit(c) : ls_binary_digit(c)) {
                j = j + 1;
            } else {
                keep = 0;
            }
        } else {
            keep = 0;
        }
    }
    return j;
}

static int ls_float_tail(const unsigned char *buf, int64_t int_end, int64_t n) {
    if (int_end + 1 < n) {
        if (ls_byte(buf, int_end) == 46) {
            return ls_digit(ls_byte(buf, int_end + 1));
        }
        return 0;
    }
    return 0;
}

static int64_t ls_number_digits_start(const unsigned char *buf, int64_t start) {
    if (ls_byte(buf, start) == 45) {
        return start + 1;
    }
    return start;
}

static int ls_number_prefixed(const unsigned char *buf, int64_t start,
                              int64_t n) {
    int64_t digits_start = ls_number_digits_start(buf, start);
    if (digits_start + 1 < n) {
        if (ls_byte(buf, digits_start) == 48) {
            int64_t prefix = ls_byte(buf, digits_start + 1);
            return prefix == 120 || prefix == 88 || prefix == 98 ||
                   prefix == 66;
        }
        return 0;
    }
    return 0;
}

static int64_t ls_number_prefix_base(const unsigned char *buf, int64_t start) {
    int64_t prefix = ls_byte(buf, ls_number_digits_start(buf, start) + 1);
    if (prefix == 120 || prefix == 88) {
        return 16;
    }
    return 2;
}

static int64_t ls_scan_decimal_number_end(const unsigned char *buf,
                                          int64_t start, int64_t n) {
    int64_t digits_start = ls_number_digits_start(buf, start);
    int64_t int_end = ls_scan_int_end(buf, digits_start, n);
    if (ls_float_tail(buf, int_end, n)) {
        return ls_scan_int_end(buf, int_end + 1, n);
    }
    return int_end;
}

static int64_t ls_scan_prefixed_int_end(const unsigned char *buf, int64_t start,
                                        int64_t n) {
    int64_t digits_start = ls_number_digits_start(buf, start);
    int64_t base = ls_number_prefix_base(buf, start);
    return ls_scan_based_int_end(buf, digits_start + 2, n, base);
}

static int64_t ls_scan_number_end(const unsigned char *buf, int64_t start,
                                  int64_t n) {
    if (ls_number_prefixed(buf, start, n)) {
        return ls_scan_prefixed_int_end(buf, start, n);
    }
    return ls_scan_decimal_number_end(buf, start, n);
}

/* `number-float?`: a prefixed literal is never a float, otherwise the integer
 * run is rescanned to look for a `.digit` tail. The rescan is the lexer's. */
static int ls_number_float(const unsigned char *buf, int64_t start, int64_t n) {
    if (ls_number_prefixed(buf, start, n)) {
        return 0;
    }
    return ls_float_tail(
        buf, ls_scan_int_end(buf, ls_number_digits_start(buf, start), n), n);
}

static int ls_negative_number_start(const unsigned char *buf, int64_t start,
                                    int64_t n) {
    if (ls_byte(buf, start) == 45) {
        if (start + 1 < n) {
            return ls_digit(ls_byte(buf, start + 1));
        }
        return 0;
    }
    return 0;
}

/* `symbol-slice-eq?` at its two call sites: the `pkg` prefix that lets a `:`
 * continue a symbol run, and the `:as` import keyword. */
static int ls_slice_pkg(const unsigned char *buf, int64_t start, int64_t end) {
    if (end - start == 3) {
        return ls_byte(buf, start) == 112 && ls_byte(buf, start + 1) == 107 &&
               ls_byte(buf, start + 2) == 103;
    }
    return 0;
}

static int ls_slice_colon_as(const unsigned char *buf, int64_t start,
                             int64_t end) {
    if (end - start == 3) {
        return ls_byte(buf, start) == 58 && ls_byte(buf, start + 1) == 97 &&
               ls_byte(buf, start + 2) == 115;
    }
    return 0;
}

static int64_t ls_scan_symbol_end(const unsigned char *buf, int64_t start,
                                  int64_t n) {
    int64_t j = start;
    int keep = 1;
    while (keep) {
        if (j < n) {
            int64_t c = ls_byte(buf, j);
            if (c == 58 && j > start && !ls_slice_pkg(buf, start, j)) {
                keep = 0;
            } else if (ls_symbol_char(c)) {
                j = j + 1;
            } else {
                keep = 0;
            }
        } else {
            keep = 0;
        }
    }
    return j;
}

/* `colon-symbol-head?`: a `:` opens a keyword symbol only when the first
 * non-space byte before it is `(`, so annotations stay standalone `:` tokens. */
static int ls_colon_symbol_head(const unsigned char *buf, int64_t start) {
    int64_t j = start - 1;
    int keep = 1;
    int result = 1;
    while (keep) {
        if (j < 0) {
            keep = 0;
        } else {
            int64_t c = ls_byte(buf, j);
            if (ls_space(c)) {
                j = j - 1;
            } else {
                result = (c == 40);
                keep = 0;
            }
        }
    }
    return result;
}

static int64_t ls_colon_token_end(const unsigned char *buf, int64_t start,
                                  int64_t n) {
    int64_t end = ls_scan_symbol_end(buf, start, n);
    if (ls_colon_symbol_head(buf, start) ||
        ls_slice_colon_as(buf, start, end)) {
        return end;
    }
    return start + 1;
}

/* `scan-str-end-result`: forward to the first unescaped `"`. A backslash
 * escapes the following byte, so `\"` stays inside the literal. */
static int64_t ls_scan_str_end(const unsigned char *buf, int64_t start,
                               int64_t n) {
    int64_t j = start;
    int keep = 1;
    while (keep) {
        if (j < n) {
            int64_t c = ls_byte(buf, j);
            if (c == 34) {
                keep = 0;
            } else if (c == 92) {
                if (j + 1 < n) {
                    j = j + 2;
                } else {
                    keep = 0;
                }
            } else {
                j = j + 1;
            }
        } else {
            keep = 0;
        }
    }
    return j;
}

static int64_t ls_scan_comment_end(const unsigned char *buf, int64_t start,
                                   int64_t n) {
    int64_t j = start;
    int keep = 1;
    while (keep) {
        if (j < n) {
            if (ls_byte(buf, j) == 10) {
                keep = 0;
            } else {
                j = j + 1;
            }
        } else {
            keep = 0;
        }
    }
    return j;
}

/* `apostrophe-escaped-char-result`: the escapes a character literal accepts. */
static int ls_escaped_char(int64_t c) {
    return c == 110 || c == 116 || c == 114 || c == 48 || c == 92 || c == 39;
}

/* `apostrophe-char-literal-result`, collapsed to the end index of the literal
 * or -1 for "this apostrophe is a quote prefix, not a character literal". */
static int64_t ls_apostrophe_char_end(const unsigned char *buf, int64_t i,
                                      int64_t n) {
    if (i + 1 < n) {
        int64_t payload = ls_byte(buf, i + 1);
        if (payload == 92) {
            int64_t esc_idx = i + 2;
            if (esc_idx < n) {
                if (ls_escaped_char(ls_byte(buf, esc_idx))) {
                    if (i + 3 < n && ls_byte(buf, i + 3) == 39) {
                        return i + 4;
                    }
                    return -1;
                }
                return -1;
            }
            return -1;
        }
        if (payload == 39 || payload == 10 || payload == 13) {
            return -1;
        }
        if (i + 2 < n) {
            if (ls_byte(buf, i + 2) == 39) {
                return i + 3;
            }
            return -1;
        }
        return -1;
    }
    return -1;
}

/* ---- the fold ---- */
/* Every token contributes its kind, its byte length, and its first byte. All
 * three products wrap modulo 2^64, matching TypeLisp's i64 arithmetic. */
static uint64_t ls_fold(uint64_t acc, uint64_t kind, uint64_t length,
                        uint64_t first) {
    return acc * 1000003u + (kind * 1315423911u + (length * 2654435761u + first));
}

/* ---- the tokenizer ---- */
/* One pass over the corpus. Line and column advance exactly as they do in
 * `lex-into-spanned-tokens-result`, including the `lex-advance-position` rescan
 * a string literal needs because it may contain newlines. */
static uint64_t ls_tokenize(const unsigned char *buf, int64_t n,
                            uint64_t seed_acc) {
    int64_t i = 0;
    int64_t line = 1;
    int64_t col = 1;
    int64_t count = 0;
    uint64_t acc = seed_acc;

    while (i < n) {
        int64_t c = ls_byte(buf, i);
        if (ls_space(c)) {
            if (c == 10) {
                line = line + 1;
                col = 1;
            } else {
                col = col + 1;
            }
            i = i + 1;
        } else if (c == 40) {
            acc = ls_fold(acc, LS_TAG_LPAREN, 1, (uint64_t)c);
            count = count + 1;
            i = i + 1;
            col = col + 1;
        } else if (c == 91) {
            acc = ls_fold(acc, LS_TAG_LBRACKET, 1, (uint64_t)c);
            count = count + 1;
            i = i + 1;
            col = col + 1;
        } else if (c == 41) {
            acc = ls_fold(acc, LS_TAG_RPAREN, 1, (uint64_t)c);
            count = count + 1;
            i = i + 1;
            col = col + 1;
        } else if (c == 93) {
            acc = ls_fold(acc, LS_TAG_RBRACKET, 1, (uint64_t)c);
            count = count + 1;
            i = i + 1;
            col = col + 1;
        } else if (c == 39) {
            int64_t end = ls_apostrophe_char_end(buf, i, n);
            if (end < 0) {
                acc = ls_fold(acc, LS_TAG_QUOTE, 1, (uint64_t)c);
                count = count + 1;
                i = i + 1;
                col = col + 1;
            } else {
                acc = ls_fold(acc, LS_TAG_CHAR, (uint64_t)(end - i),
                              (uint64_t)c);
                count = count + 1;
                col = col + (end - i);
                i = end;
            }
        } else if (c == 96) {
            acc = ls_fold(acc, LS_TAG_BACKTICK, 1, (uint64_t)c);
            count = count + 1;
            i = i + 1;
            col = col + 1;
        } else if (c == 44) {
            if (i + 1 < n && ls_byte(buf, i + 1) == 64) {
                acc = ls_fold(acc, LS_TAG_COMMA_AT, 2, (uint64_t)c);
                i = i + 2;
                col = col + 2;
            } else {
                acc = ls_fold(acc, LS_TAG_COMMA, 1, (uint64_t)c);
                i = i + 1;
                col = col + 1;
            }
            count = count + 1;
        } else if (c == 34) {
            int64_t start = i + 1;
            int64_t end = ls_scan_str_end(buf, start, n);
            int64_t scan = i;
            acc = ls_fold(acc, LS_TAG_STR, (uint64_t)(end + 1 - i),
                          (uint64_t)c);
            count = count + 1;
            while (scan < end + 1) {
                if (ls_byte(buf, scan) == 10) {
                    line = line + 1;
                    col = 1;
                } else {
                    col = col + 1;
                }
                scan = scan + 1;
            }
            i = end + 1;
        } else if (c == 59) {
            int64_t end = ls_scan_comment_end(buf, i + 1, n);
            col = col + (end - i);
            i = end;
        } else if (ls_digit(c) || ls_negative_number_start(buf, i, n)) {
            int64_t end = ls_scan_number_end(buf, i, n);
            int64_t kind = ls_number_float(buf, i, n) ? LS_TAG_FLOAT
                                                      : LS_TAG_INT;
            acc = ls_fold(acc, (uint64_t)kind, (uint64_t)(end - i),
                          (uint64_t)c);
            count = count + 1;
            col = col + (end - i);
            i = end;
        } else if (c == 58) {
            int64_t end = ls_colon_token_end(buf, i, n);
            acc = ls_fold(acc, LS_TAG_SYM, (uint64_t)(end - i), (uint64_t)c);
            count = count + 1;
            col = col + (end - i);
            i = end;
        } else if (ls_symbol_char(c)) {
            int64_t end = ls_scan_symbol_end(buf, i, n);
            acc = ls_fold(acc, LS_TAG_SYM, (uint64_t)(end - i), (uint64_t)c);
            count = count + 1;
            col = col + (end - i);
            i = end;
        } else {
            acc = ls_fold(acc, LS_TAG_UNEXPECTED, 1, (uint64_t)c);
            count = count + 1;
            i = i + 1;
            col = col + 1;
        }
    }

    return acc * 1000003u +
           ((uint64_t)line * 31u + ((uint64_t)col * 131u + (uint64_t)count));
}

/* Load the corpus once, then tokenize it `rounds` times. */
static uint64_t ls_bench(const char *path, int64_t rounds) {
    FILE *handle = fopen(path, "rb");
    unsigned char *buf = 0;
    long size = 0;
    int64_t n = 0;
    uint64_t acc = 0;

    if (!handle) {
        abort();
    }
    if (fseek(handle, 0, SEEK_END) != 0) {
        abort();
    }
    size = ftell(handle);
    if (size < 0) {
        abort();
    }
    if (fseek(handle, 0, SEEK_SET) != 0) {
        abort();
    }
    buf = (unsigned char *)malloc((size_t)size + 1);
    if (!buf) {
        abort();
    }
    if (fread(buf, 1, (size_t)size, handle) != (size_t)size) {
        abort();
    }
    fclose(handle);
    n = (int64_t)size;

    for (int64_t round = 0; round < rounds; round += 1) {
        acc = ls_tokenize(buf, n, acc);
    }
    free(buf);
    return acc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)ls_bench(path, rounds));
    return 0;
}
