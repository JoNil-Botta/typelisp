/* benchmarks/peephole_lines/baseline.c - clang C baseline for peephole_lines.
 *
 * Equivalent to benchmarks/peephole_lines/bench.tl: the TypeLisp backend's
 * assembly-text optimizer -- the fallthrough-jump scan, the streaming peephole
 * that classifies every emitted line, applies the pair rule set and the
 * per-register reload-elision owner map while pushing line records, and the
 * dead-store sweep over those records -- run over the compiler's own emitted
 * assembly.
 *
 * Mirrored compiler functions (all in src/compiler_backend.tl) and the exact
 * kept/dropped list are documented in bench.tl and README.md.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum here is formed in
 * uint64_t so the C side wraps identically, and every other value in this
 * workload stays far inside 63 bits. The printed decimal is the checksum
 * reinterpreted as a signed 64-bit integer, matching TypeLisp's print of an
 * i64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define PL_HASH_BASIS 1469598103934665603ULL
#define PL_HASH_PRIME 1099511628211ULL

/* compiler-backend-peephole-owner-key-stack-bias */
#define PL_OWNER_KEY_BIAS 1073741824LL

/* compiler-backend-peephole-op-*-flag */
#define PL_OP_REGISTER 1
#define PL_OP_STACK 2
#define PL_OP_LOCAL_FRAME 4
#define PL_OP_R10_BASE 8

/* Line descriptor fields (CompilerBackendPeepholeLine). */
enum {
    PL_F_START = 0,
    PL_F_END = 1,
    PL_F_NEWLINE = 2,
    PL_F_OWNED = 3,
    PL_F_MN_START = 4,
    PL_F_MN_LEN = 5,
    PL_F_MOVQ = 6,
    PL_F_LABEL = 7,
    PL_F_ABORT = 8,
    PL_F_CLEARS = 9,
    PL_F_CALL = 10,
    PL_F_SINGLE = 11,
    PL_F_ZEXT = 12,
    PL_F_HASOPS = 13,
    PL_F_SRC_START = 14,
    PL_F_SRC_END = 15,
    PL_F_DST_START = 16,
    PL_F_DST_END = 17,
    PL_F_SRC_KEY = 18,
    PL_F_DST_KEY = 19,
    PL_F_SRC_FLAGS = 20,
    PL_F_DST_FLAGS = 21,
    PL_F_SRC_REG = 22,
    PL_F_DST_REG = 23,
    PL_F_LAST_REG = 24,
    PL_F_COUNT = 25
};

/* Sweep record flags. */
#define PL_SW_LABEL 1
#define PL_SW_LEAQ 2
#define PL_SW_PUSH 4
#define PL_SW_POP 8
#define PL_SW_RSP_DST 16
#define PL_SW_TRACKED 32
#define PL_SW_SUBQ 64
#define PL_SW_FATAL 128

#define PL_NONE 4611686018427387904LL

static char *pl_text;
static int64_t pl_len;
static int64_t *pl_chunk_start;
static int64_t *pl_chunk_end;
static int64_t pl_chunk_count;

static int64_t pl_pending[PL_F_COUNT];
static int64_t pl_next[PL_F_COUNT];

/* Line records (CompilerBackendPeepholeLineVec). */
static int64_t *pl_rec_owned;
static int64_t *pl_rec_src_start;
static int64_t *pl_rec_src_end;
static int64_t *pl_rec_dst_start;
static int64_t *pl_rec_dst_end;
static int64_t *pl_rec_flags;
static int64_t *pl_rec_cand;
static int64_t *pl_rec_read;
static int64_t *pl_rec_width;
static int64_t *pl_rec_value;
static int64_t *pl_rec_live;
static int64_t pl_rec_len;

/* Sweep scratch. */
static int64_t *pl_sweep_cand_pos;
static int64_t *pl_sweep_cand_off;
static int64_t *pl_sweep_read_lo;
static int64_t *pl_sweep_read_hi;

/* Per-register owner map (CompilerBackendPeepholeOwners). */
static int64_t pl_owners[14];

static int64_t pl_kept;
static int64_t pl_dropped;
static int64_t pl_rule1;
static int64_t pl_rule2;
static int64_t pl_rule3;
static int64_t pl_rule4;
static int64_t pl_elided;
static int64_t pl_reused;
static int64_t pl_fallthrough;
static int64_t pl_swept;

static uint64_t pl_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * PL_HASH_PRIME;
}

static int64_t *pl_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

/* An unreadable corpus becomes an empty text, exactly as TypeLisp's
 * `io.read-file-or path ""` does, so both sides then fold zero chunks, print
 * the same deterministic checksum and exit 0. */
static void pl_empty_text(void) {
    pl_text = (char *)malloc(1);
    if (!pl_text) {
        abort();
    }
    pl_text[0] = '\0';
    pl_len = 0;
}

static void pl_read_file(const char *path) {
    FILE *handle = fopen(path, "rb");
    long size;
    if (!handle) {
        pl_empty_text();
        return;
    }
    if (fseek(handle, 0, SEEK_END) != 0) {
        fclose(handle);
        pl_empty_text();
        return;
    }
    size = ftell(handle);
    if (size < 0 || fseek(handle, 0, SEEK_SET) != 0) {
        fclose(handle);
        pl_empty_text();
        return;
    }
    /* A path that opens but is not a readable regular file (a directory, for
     * instance) can report a nonsense size here. Degrade rather than abort, so
     * the exit status still matches TypeLisp's `read-file-or` fallback. */
    pl_text = (char *)malloc((size_t)size + 1);
    if (!pl_text) {
        fclose(handle);
        pl_empty_text();
        return;
    }
    if (fread(pl_text, 1, (size_t)size, handle) != (size_t)size) {
        free(pl_text);
        fclose(handle);
        pl_empty_text();
        return;
    }
    pl_text[size] = '\0';
    fclose(handle);
    pl_len = (int64_t)size;
}

/* compiler-backend-peephole-byte-at */
static int64_t pl_byte_at(int64_t i) {
    return (i >= 0 && i < pl_len) ? (int64_t)(unsigned char)pl_text[i] : -1;
}

/* compiler-backend-peephole-line-end */
static int64_t pl_line_end(int64_t i, int64_t n) {
    int64_t scan = i;
    while (scan < n && pl_byte_at(scan) != 10) {
        scan += 1;
    }
    return scan;
}

/* compiler-backend-peephole-ranges-eq? */
static int pl_ranges_eq(int64_t a_start, int64_t a_end, int64_t b_start,
                        int64_t b_end) {
    int64_t i = 0;
    int64_t n = a_end - a_start;
    if (n != b_end - b_start) {
        return 0;
    }
    while (i < n) {
        if (pl_byte_at(a_start + i) != pl_byte_at(b_start + i)) {
            return 0;
        }
        i += 1;
    }
    return 1;
}

/* compiler-backend-peephole-token-len */
static int64_t pl_token_len(int64_t i, int64_t end) {
    int64_t scan = i;
    while (scan < end && pl_byte_at(scan) != 32) {
        scan += 1;
    }
    return scan - i;
}

/* compiler-backend-peephole-find-comma-space-range */
static int64_t pl_find_comma_space(int64_t start, int64_t end) {
    int64_t i = start;
    while (i + 1 < end) {
        if (pl_byte_at(i) == 44 && pl_byte_at(i + 1) == 32) {
            return i;
        }
        i += 1;
    }
    return -1;
}

/* compiler-backend-peephole-movq-prefix-at-range? */
static int pl_movq_prefix(int64_t start, int64_t end) {
    return start + 9 <= end && pl_byte_at(start) == 32 &&
           pl_byte_at(start + 1) == 32 && pl_byte_at(start + 2) == 32 &&
           pl_byte_at(start + 3) == 32 && pl_byte_at(start + 4) == 109 &&
           pl_byte_at(start + 5) == 111 && pl_byte_at(start + 6) == 118 &&
           pl_byte_at(start + 7) == 113 && pl_byte_at(start + 8) == 32;
}

/* compiler-backend-peephole-mnemonic-zext? */
static int pl_mnemonic_zext(int64_t i, int64_t mlen) {
    return mlen == 6 && pl_byte_at(i) == 109 && pl_byte_at(i + 1) == 111 &&
           pl_byte_at(i + 2) == 118 && pl_byte_at(i + 3) == 122 &&
           pl_byte_at(i + 4) == 98 &&
           (pl_byte_at(i + 5) == 113 || pl_byte_at(i + 5) == 108);
}

/* compiler-backend-peephole-mnemonic-call? */
static int pl_mnemonic_call(int64_t i, int64_t mlen) {
    return (mlen == 4 || mlen == 5) && pl_byte_at(i) == 99 &&
           pl_byte_at(i + 1) == 97 && pl_byte_at(i + 2) == 108 &&
           pl_byte_at(i + 3) == 108 &&
           (mlen == 4 || pl_byte_at(i + 4) == 113);
}

/* compiler-backend-peephole-cmp-or-test-token? */
static int pl_cmp_or_test(int64_t i, int64_t mlen) {
    int64_t suffix = pl_byte_at(i + mlen - 1);
    int suffixed = suffix == 113 || suffix == 108 || suffix == 119 || suffix == 98;
    if ((mlen == 3 || (mlen == 4 && suffixed)) && pl_byte_at(i) == 99 &&
        pl_byte_at(i + 1) == 109 && pl_byte_at(i + 2) == 112) {
        return 1;
    }
    if ((mlen == 4 || (mlen == 5 && suffixed)) && pl_byte_at(i) == 116 &&
        pl_byte_at(i + 1) == 101 && pl_byte_at(i + 2) == 115 &&
        pl_byte_at(i + 3) == 116) {
        return 1;
    }
    return 0;
}

/* compiler-backend-peephole-mnemonic-single-dest? */
static int pl_single_dest(int64_t i, int64_t mlen) {
    int64_t b0;
    int64_t b1;
    int64_t b2;
    int64_t base3;
    int64_t suffix;
    if (mlen < 3) {
        return 0;
    }
    b0 = pl_byte_at(i);
    b1 = pl_byte_at(i + 1);
    b2 = pl_byte_at(i + 2);
    base3 = b0 + b1 * 256 + b2 * 65536;
    suffix = pl_byte_at(i + mlen - 1);
    if (b0 == 115 && b1 == 101 && b2 == 116) {
        return 1;
    }
    if (mlen == 7) {
        return base3 == 7761773 && pl_byte_at(i + 3) == 97 &&
               pl_byte_at(i + 4) == 98 && pl_byte_at(i + 5) == 115 &&
               pl_byte_at(i + 6) == 113;
    }
    if (mlen == 6) {
        int64_t kind = pl_byte_at(i + 3);
        int64_t width = pl_byte_at(i + 4);
        return base3 == 7761773 && pl_byte_at(i + 5) == 113 &&
               ((kind == 122 && (width == 98 || width == 119)) ||
                (kind == 115 && (width == 98 || width == 119 || width == 108)));
    }
    if (!(suffix == 113 || suffix == 108 || suffix == 119 || suffix == 98)) {
        return 0;
    }
    if (mlen == 3 && b0 == 111 && b1 == 114) {
        return 1;
    }
    if (mlen == 4) {
        return (suffix != 113 && base3 == 7761773) || base3 == 6579297 ||
               base3 == 6452595 || base3 == 6581857 || base3 == 7499640 ||
               base3 == 7104627 || base3 == 7497843 || base3 == 7496051 ||
               base3 == 7102835 || base3 == 6776174 || base3 == 7630702 ||
               base3 == 6516329 || base3 == 6514020 || base3 == 6382956;
    }
    return 0;
}

/* compiler-backend-peephole-reg-index-range */
static int64_t pl_reg_index(int64_t start, int64_t end) {
    int64_t n = end - start;
    int64_t b0;
    int64_t b1;
    int64_t b2;
    int64_t b3;
    if (n < 3 || n > 4) {
        return -1;
    }
    b0 = pl_byte_at(start);
    b1 = pl_byte_at(start + 1);
    b2 = pl_byte_at(start + 2);
    if (b0 != 37 || b1 != 114) {
        return -1;
    }
    if (n == 3) {
        if (b2 == 56) {
            return 6;
        }
        if (b2 == 57) {
            return 7;
        }
        return -1;
    }
    b3 = pl_byte_at(start + 3);
    if (b2 == 97) {
        return b3 == 120 ? 0 : -1;
    }
    if (b2 == 99) {
        return b3 == 120 ? 1 : -1;
    }
    if (b2 == 100) {
        if (b3 == 120) {
            return 2;
        }
        if (b3 == 105) {
            return 5;
        }
        return -1;
    }
    if (b2 == 98) {
        return b3 == 120 ? 3 : -1;
    }
    if (b2 == 115) {
        return b3 == 105 ? 4 : -1;
    }
    if (b2 == 49) {
        if (b3 == 48) {
            return 8;
        }
        if (b3 == 49) {
            return 9;
        }
        if (b3 == 50) {
            return 10;
        }
        if (b3 == 51) {
            return 11;
        }
        if (b3 == 52) {
            return 12;
        }
        if (b3 == 53) {
            return 13;
        }
        return -1;
    }
    return -1;
}

/* compiler-backend-peephole-last-operand-reg-index */
static int64_t pl_last_operand_reg(int64_t start, int64_t end) {
    int64_t cut = -1;
    int64_t i = start;
    while (i + 1 < end) {
        if (pl_byte_at(i) == 44 && pl_byte_at(i + 1) == 32) {
            cut = i;
        }
        i += 1;
    }
    if (cut < 0) {
        return -1;
    }
    return pl_reg_index(cut + 2, end);
}

/* compiler-backend-peephole-memory-base-range */
static int64_t pl_memory_base(int64_t start, int64_t end) {
    int64_t s;
    int64_t b3;
    int64_t b4;
    if (end - start < 6) {
        return 0;
    }
    s = end - 6;
    if (!(pl_byte_at(s) == 40 && pl_byte_at(s + 1) == 37 &&
          pl_byte_at(s + 2) == 114 && pl_byte_at(s + 5) == 41)) {
        return 0;
    }
    b3 = pl_byte_at(s + 3);
    b4 = pl_byte_at(s + 4);
    if (b4 == 112) {
        if (b3 == 98) {
            return 1;
        }
        if (b3 == 115) {
            return 2;
        }
        if (b3 == 105) {
            return 3;
        }
        return 0;
    }
    if (b3 == 49 && b4 == 48) {
        return 4;
    }
    return 0;
}

/* compiler-backend-peephole-decimal-range-valid? */
static int pl_decimal_valid(int64_t start, int64_t end) {
    int64_t i;
    if (start >= end) {
        return 0;
    }
    i = pl_byte_at(start) == 45 ? start + 1 : start;
    if (i >= end) {
        return 0;
    }
    while (i < end) {
        int64_t b = pl_byte_at(i);
        if (b < 48 || b > 57) {
            return 0;
        }
        i += 1;
    }
    return 1;
}

/* compiler-backend-peephole-decimal-range-value */
static int64_t pl_decimal_value(int64_t start, int64_t end) {
    int negative = pl_byte_at(start) == 45;
    int64_t i = negative ? start + 1 : start;
    int64_t value = 0;
    while (i < end) {
        value = value * 10 + (pl_byte_at(i) - 48);
        i += 1;
    }
    return negative ? -value : value;
}

/* compiler-backend-peephole-stack-owner-key-from-parts */
static int64_t pl_stack_owner_key(int64_t base, int64_t offset, int explicit_) {
    if (offset < -PL_OWNER_KEY_BIAS || offset > PL_OWNER_KEY_BIAS) {
        return 0;
    }
    return 1 + 4 * (offset + PL_OWNER_KEY_BIAS) + base * 2 + (explicit_ ? 1 : 0);
}

/* compiler-backend-peephole-owner-key-from-range, without the `SYM(%rip)`
 * global keys (see the header's dropped list). */
static int64_t pl_owner_key(int64_t start, int64_t end, int64_t memory_base) {
    int64_t prefix_end = end - 6;
    if (memory_base == 1 || memory_base == 2) {
        int64_t base = memory_base == 1 ? 0 : 1;
        if (prefix_end == start) {
            return pl_stack_owner_key(base, 0, 0);
        }
        if (pl_decimal_valid(start, prefix_end)) {
            return pl_stack_owner_key(base, pl_decimal_value(start, prefix_end), 1);
        }
        return 0;
    }
    return 0;
}

/* compiler-backend-peephole-stack-parens-range */
static int64_t pl_stack_parens(int64_t start, int64_t end) {
    int64_t i = start;
    int64_t bits = 0;
    while (i + 6 <= end) {
        if (pl_byte_at(i) == 40 && pl_byte_at(i + 1) == 37 &&
            pl_byte_at(i + 2) == 114 && pl_byte_at(i + 4) == 112 &&
            pl_byte_at(i + 5) == 41) {
            int64_t b3 = pl_byte_at(i + 3);
            if (b3 == 98) {
                bits |= 1;
            } else if (b3 == 115) {
                bits |= 2;
            }
        }
        i += 1;
    }
    return bits;
}

/* compiler-backend-peephole-operand-flags */
static int64_t pl_operand_flags(int64_t start, int64_t end, int64_t key,
                                int64_t memory_base) {
    int register_ = start < end && pl_byte_at(start) == 37;
    int packed_stack = key > 0;
    int base_rbp = memory_base == 1;
    int base_rsp = memory_base == 2;
    int leading_minus = start < end && pl_byte_at(start) == 45;
    int64_t parens =
        (!packed_stack && (base_rbp || (!base_rsp && end - start >= 6)))
            ? pl_stack_parens(start, end)
            : 0;
    int stack = packed_stack || base_rbp || base_rsp || parens != 0;
    int local_frame;
    int r10_base = memory_base == 4;
    if (packed_stack) {
        local_frame = ((key - 1) & 2) != 0 || leading_minus;
    } else if (base_rsp) {
        local_frame = 1;
    } else if (base_rbp) {
        local_frame = leading_minus || (parens & 2) != 0;
    } else {
        local_frame = stack && ((parens & 2) != 0 ||
                                (leading_minus && (parens & 1) != 0));
    }
    return (register_ ? PL_OP_REGISTER : 0) + (stack ? PL_OP_STACK : 0) +
           (local_frame ? PL_OP_LOCAL_FRAME : 0) + (r10_base ? PL_OP_R10_BASE : 0);
}

static int pl_suffix_abort(int64_t start, int64_t end) {
    return end - start >= 5 && pl_byte_at(end - 5) == 97 &&
           pl_byte_at(end - 4) == 98 && pl_byte_at(end - 3) == 111 &&
           pl_byte_at(end - 2) == 114 && pl_byte_at(end - 1) == 116;
}

/* compiler-backend-peephole-line-noreturn-abort? */
static int pl_noreturn_abort(int64_t start, int64_t end) {
    int64_t i = start;
    int64_t e = end;
    while (i < end && pl_byte_at(i) == 32) {
        i += 1;
    }
    while (e > i && pl_byte_at(e - 1) == 32) {
        e -= 1;
    }
    return e - i > 5 && pl_byte_at(i) == 99 && pl_byte_at(i + 1) == 97 &&
           pl_byte_at(i + 2) == 108 && pl_byte_at(i + 3) == 108 &&
           pl_byte_at(i + 4) == 32 && pl_byte_at(i + 5) == 116 &&
           pl_byte_at(i + 6) == 108 && pl_byte_at(i + 7) == 95 &&
           pl_suffix_abort(i + 8, e);
}

/* compiler-backend-peephole-parse-line */
static void pl_parse_line(int64_t *slot, int64_t start, int64_t end,
                          int newline) {
    int64_t ms = start;
    int64_t mlen;
    int64_t operand_start;
    int has_operands = 0;
    int64_t comma = -1;
    int movq_prefix;
    int zext;
    int is_movq;
    int64_t src_start;
    int64_t src_end;
    int64_t dst_start;
    int is_label;
    int cmp;
    int clears;
    int call;
    int single;
    int64_t last_reg;
    int64_t src_base;
    int64_t dst_base;
    int64_t src_key;
    int64_t dst_key;

    while (ms < end && pl_byte_at(ms) == 32) {
        ms += 1;
    }
    mlen = pl_token_len(ms, end);
    operand_start = ms + mlen;
    movq_prefix = pl_movq_prefix(start, end);
    zext = pl_mnemonic_zext(ms, mlen);
    if (movq_prefix || zext) {
        while (operand_start < end && pl_byte_at(operand_start) == 32) {
            operand_start += 1;
        }
        comma = pl_find_comma_space(operand_start, end);
        if (comma > operand_start && comma + 2 < end) {
            has_operands = 1;
        }
    }
    is_movq = has_operands && movq_prefix;
    src_start = operand_start;
    src_end = has_operands ? comma : operand_start;
    dst_start = has_operands ? comma + 2 : end;
    is_label = ms < end && pl_byte_at(end - 1) == 58;
    cmp = pl_cmp_or_test(ms, mlen);
    if (ms >= end) {
        clears = 0;
    } else if (is_label) {
        clears = 1;
    } else if (pl_byte_at(ms) == 46) {
        clears = 0;
    } else if (pl_byte_at(ms) == 106) {
        clears = 0;
    } else if (cmp) {
        clears = 0;
    } else {
        clears = 1;
    }
    call = pl_mnemonic_call(ms, mlen);
    single = !is_movq && !is_label && clears && !call && pl_single_dest(ms, mlen);
    last_reg = (single || zext) ? pl_last_operand_reg(start, end) : -1;
    src_base = is_movq ? pl_memory_base(src_start, src_end) : 0;
    dst_base = is_movq ? pl_memory_base(dst_start, end) : 0;
    src_key = is_movq ? pl_owner_key(src_start, src_end, src_base) : 0;
    dst_key = is_movq ? pl_owner_key(dst_start, end, dst_base) : 0;

    slot[PL_F_START] = start;
    slot[PL_F_END] = end;
    slot[PL_F_NEWLINE] = newline ? 1 : 0;
    slot[PL_F_OWNED] = 0;
    slot[PL_F_MN_START] = ms;
    slot[PL_F_MN_LEN] = mlen;
    slot[PL_F_MOVQ] = is_movq ? 1 : 0;
    slot[PL_F_LABEL] = is_label ? 1 : 0;
    slot[PL_F_ABORT] = (call && pl_noreturn_abort(start, end)) ? 1 : 0;
    slot[PL_F_CLEARS] = clears ? 1 : 0;
    slot[PL_F_CALL] = call ? 1 : 0;
    slot[PL_F_SINGLE] = single ? 1 : 0;
    slot[PL_F_ZEXT] = zext ? 1 : 0;
    slot[PL_F_HASOPS] = has_operands ? 1 : 0;
    slot[PL_F_SRC_START] = src_start;
    slot[PL_F_SRC_END] = src_end;
    slot[PL_F_DST_START] = dst_start;
    slot[PL_F_DST_END] = end;
    slot[PL_F_SRC_KEY] = src_key;
    slot[PL_F_DST_KEY] = dst_key;
    slot[PL_F_SRC_FLAGS] =
        is_movq ? pl_operand_flags(src_start, src_end, src_key, src_base) : 0;
    slot[PL_F_DST_FLAGS] =
        is_movq ? pl_operand_flags(dst_start, end, dst_key, dst_base) : 0;
    slot[PL_F_SRC_REG] = is_movq ? pl_reg_index(src_start, src_end) : -1;
    slot[PL_F_DST_REG] = is_movq ? pl_reg_index(dst_start, end) : -1;
    slot[PL_F_LAST_REG] = last_reg;
}

/* compiler-backend-peephole-owned-line for the synthesized `    movq SRC, DST`.
 * The two operand spans already exist in the corpus, so the descriptor is
 * derived directly instead of formatting and re-parsing the text. */
static void pl_owned_line(int64_t *slot, int64_t src_start, int64_t src_end,
                          int64_t dst_start, int64_t dst_end, int64_t newline) {
    int64_t src_base = pl_memory_base(src_start, src_end);
    int64_t dst_base = pl_memory_base(dst_start, dst_end);
    int64_t src_key = pl_owner_key(src_start, src_end, src_base);
    int64_t dst_key = pl_owner_key(dst_start, dst_end, dst_base);
    slot[PL_F_START] = -1;
    slot[PL_F_END] = -1;
    slot[PL_F_NEWLINE] = newline;
    slot[PL_F_OWNED] = 1;
    slot[PL_F_MN_START] = -1;
    slot[PL_F_MN_LEN] = 4;
    slot[PL_F_MOVQ] = 1;
    slot[PL_F_LABEL] = 0;
    slot[PL_F_ABORT] = 0;
    slot[PL_F_CLEARS] = 1;
    slot[PL_F_CALL] = 0;
    slot[PL_F_SINGLE] = 0;
    slot[PL_F_ZEXT] = 0;
    slot[PL_F_HASOPS] = 1;
    slot[PL_F_SRC_START] = src_start;
    slot[PL_F_SRC_END] = src_end;
    slot[PL_F_DST_START] = dst_start;
    slot[PL_F_DST_END] = dst_end;
    slot[PL_F_SRC_KEY] = src_key;
    slot[PL_F_DST_KEY] = dst_key;
    slot[PL_F_SRC_FLAGS] = pl_operand_flags(src_start, src_end, src_key, src_base);
    slot[PL_F_DST_FLAGS] = pl_operand_flags(dst_start, dst_end, dst_key, dst_base);
    slot[PL_F_SRC_REG] = pl_reg_index(src_start, src_end);
    slot[PL_F_DST_REG] = pl_reg_index(dst_start, dst_end);
    slot[PL_F_LAST_REG] = -1;
}

/* compiler-backend-peephole-line-copy */
static void pl_copy_line(int64_t *dst, const int64_t *src) {
    int64_t i = 0;
    while (i < PL_F_COUNT) {
        dst[i] = src[i];
        i += 1;
    }
}

/* compiler-backend-peephole-line-self-move-desc? */
static int pl_self_move(const int64_t *slot) {
    return slot[PL_F_MOVQ] == 1 && (slot[PL_F_SRC_FLAGS] & 3) != 0 &&
           pl_ranges_eq(slot[PL_F_SRC_START], slot[PL_F_SRC_END],
                        slot[PL_F_DST_START], slot[PL_F_DST_END]);
}

/* compiler-backend-peephole-redundant-zext-pair-desc? */
static int pl_redundant_zext(const int64_t *pending, const int64_t *next) {
    int64_t reg;
    int64_t src_start;
    int64_t src_end;
    int64_t last;
    if (pending[PL_F_ZEXT] == 0) {
        return 0;
    }
    reg = pending[PL_F_LAST_REG];
    if (reg < 0) {
        return 0;
    }
    if (next[PL_F_HASOPS] == 0 || next[PL_F_MN_LEN] != 6 ||
        !pl_mnemonic_zext(next[PL_F_MN_START], 6) ||
        pl_byte_at(next[PL_F_MN_START] + 5) != 113) {
        return 0;
    }
    src_start = next[PL_F_SRC_START];
    src_end = next[PL_F_SRC_END];
    if (src_start == src_end || pl_byte_at(src_start) != 37) {
        return 0;
    }
    last = pl_byte_at(src_end - 1);
    if (!(last == 108 || last == 98)) {
        return 0;
    }
    return pl_reg_index(src_start, src_end) == reg &&
           next[PL_F_LAST_REG] == reg;
}

/* compiler-backend-peephole-pair-action-desc */
static int64_t pl_pair_action(const int64_t *pending, const int64_t *next) {
    int64_t pss;
    int64_t pse;
    int64_t pds;
    int64_t pde;
    int64_t nss;
    int64_t nse;
    int64_t nds;
    int64_t nde;
    int64_t psf;
    int64_t pdf;
    int64_t nsf;
    int64_t ndf;
    if (pl_redundant_zext(pending, next)) {
        return 2;
    }
    if (pending[PL_F_MOVQ] == 0) {
        return 0;
    }
    if (pl_self_move(pending)) {
        return 1;
    }
    if (next[PL_F_MOVQ] == 0) {
        return 0;
    }
    pss = pending[PL_F_SRC_START];
    pse = pending[PL_F_SRC_END];
    pds = pending[PL_F_DST_START];
    pde = pending[PL_F_DST_END];
    nss = next[PL_F_SRC_START];
    nse = next[PL_F_SRC_END];
    nds = next[PL_F_DST_START];
    nde = next[PL_F_DST_END];
    psf = pending[PL_F_SRC_FLAGS];
    pdf = pending[PL_F_DST_FLAGS];
    nsf = next[PL_F_SRC_FLAGS];
    ndf = next[PL_F_DST_FLAGS];
    if ((psf & PL_OP_REGISTER) != 0 && (pdf & PL_OP_LOCAL_FRAME) != 0 &&
        (nsf & PL_OP_REGISTER) != 0 && (ndf & PL_OP_LOCAL_FRAME) != 0 &&
        pl_ranges_eq(pds, pde, nds, nde)) {
        return 1;
    }
    if ((psf & 3) != 0 && (pdf & 3) != 0 && (nsf & 3) != 0 && (ndf & 3) != 0 &&
        ((pl_ranges_eq(pss, pse, nss, nse) && pl_ranges_eq(pds, pde, nds, nde)) ||
         (pl_ranges_eq(pds, pde, nss, nse) && pl_ranges_eq(pss, pse, nds, nde)))) {
        return 2;
    }
    if ((psf & PL_OP_REGISTER) != 0 && (pdf & PL_OP_LOCAL_FRAME) != 0 &&
        (nsf & PL_OP_LOCAL_FRAME) != 0 && (ndf & PL_OP_REGISTER) != 0 &&
        pl_ranges_eq(pds, pde, nss, nse)) {
        return 3;
    }
    if ((psf & PL_OP_REGISTER) != 0 && pl_reg_index(pss, pse) != 8 &&
        pending[PL_F_DST_REG] == 8 && (nsf & PL_OP_R10_BASE) != 0 &&
        (ndf & PL_OP_REGISTER) != 0 && next[PL_F_DST_REG] == 8) {
        return 4;
    }
    return 0;
}

/* compiler-backend-peephole-owners-clear-slot */
static void pl_owners_clear_slot(int64_t slot) {
    int64_t i = 0;
    while (i < 14) {
        if (pl_owners[i] == slot) {
            pl_owners[i] = 0;
        }
        i += 1;
    }
}

/* compiler-backend-peephole-owners-find-reg-for-slot-index */
static int64_t pl_owners_find_reg(int64_t slot, int64_t exclude) {
    int64_t i = 0;
    if (slot == 0) {
        return -1;
    }
    while (i < 14) {
        if (i != exclude && pl_owners[i] == slot) {
            return i;
        }
        i += 1;
    }
    return -1;
}

/* compiler-backend-peephole-owners-clear-call-clobbers */
static void pl_owners_clear_call(void) {
    int64_t i = 0;
    while (i < 14) {
        if (i == 3 || i >= 10) {
            if (!(pl_owners[i] > 0)) {
                pl_owners[i] = 0;
            }
        } else {
            pl_owners[i] = 0;
        }
        i += 1;
    }
}

static void pl_owners_empty(void) {
    int64_t i = 0;
    while (i < 14) {
        pl_owners[i] = 0;
        i += 1;
    }
}

/* compiler-backend-peephole-movq-owners-transfer-keyed-index */
static void pl_owners_transfer(int64_t src_reg, int64_t dst_reg, int64_t src_key,
                               int64_t dst_key) {
    if (dst_key > 0) {
        pl_owners_clear_slot(dst_key);
        if (src_reg >= 0 && pl_owners[src_reg] == 0) {
            pl_owners[src_reg] = dst_key;
        }
    } else if (dst_reg >= 0) {
        pl_owners[dst_reg] = src_key;
    } else {
        pl_owners_empty();
    }
}

/* compiler-backend-peephole-line-clobber-owners-desc. `_prev_abort` is the
 * compiler's guard-ok-label refinement, which needs the backend's carry-safe
 * label set; see the header's dropped list. */
static void pl_clobber_owners(const int64_t *slot, int64_t _prev_abort) {
    (void)_prev_abort;
    if (slot[PL_F_ABORT] == 1) {
        return;
    }
    if (slot[PL_F_LABEL] == 1) {
        pl_owners_empty();
        return;
    }
    if (slot[PL_F_CLEARS] == 0) {
        return;
    }
    if (slot[PL_F_CALL] == 1) {
        pl_owners_clear_call();
        return;
    }
    if (slot[PL_F_SINGLE] == 1) {
        int64_t dreg = slot[PL_F_LAST_REG];
        if (dreg < 0) {
            pl_owners_empty();
        } else {
            pl_owners[dreg] = 0;
        }
        return;
    }
    pl_owners_empty();
}

/* Does the line end with the bare `%rsp` destination operand? */
static int pl_tail_is_rsp(int64_t end) {
    return end >= 4 && pl_byte_at(end - 4) == 37 && pl_byte_at(end - 3) == 114 &&
           pl_byte_at(end - 2) == 115 && pl_byte_at(end - 1) == 112;
}

/* `(%rsp,` -- an indexed stack reference the sweep cannot replay. */
static int pl_indexed_rsp(int64_t start, int64_t end) {
    int64_t i = start;
    while (i + 6 <= end) {
        if (pl_byte_at(i) == 40 && pl_byte_at(i + 1) == 37 &&
            pl_byte_at(i + 2) == 114 && pl_byte_at(i + 3) == 115 &&
            pl_byte_at(i + 4) == 112 && pl_byte_at(i + 5) == 44) {
            return 1;
        }
        i += 1;
    }
    return 0;
}

/* Access width from the mnemonic's size suffix. */
static int64_t pl_access_width(const int64_t *slot) {
    int64_t ms;
    int64_t mlen;
    int64_t suffix;
    if (slot[PL_F_OWNED] == 1) {
        return 8;
    }
    ms = slot[PL_F_MN_START];
    mlen = slot[PL_F_MN_LEN];
    if (mlen < 2) {
        return 8;
    }
    suffix = pl_byte_at(ms + mlen - 1);
    if (suffix == 113) {
        return 8;
    }
    if (suffix == 108) {
        return 4;
    }
    if (suffix == 119) {
        return 2;
    }
    if (suffix == 98) {
        return 1;
    }
    return 8;
}

/* The displacement of an operand that ends in `(%rsp)`. */
static int64_t pl_rsp_displacement(int64_t start, int64_t end) {
    int64_t prefix_end = end - 6;
    if (prefix_end == start) {
        return 0;
    }
    if (pl_decimal_valid(start, prefix_end)) {
        return pl_decimal_value(start, prefix_end);
    }
    return PL_NONE;
}

/* The first `N(%rsp)` displacement in a byte range. */
static int64_t pl_first_rsp_read(int64_t start, int64_t end) {
    int64_t i = start;
    while (i + 6 <= end) {
        if (pl_byte_at(i) == 40 && pl_byte_at(i + 1) == 37 &&
            pl_byte_at(i + 2) == 114 && pl_byte_at(i + 3) == 115 &&
            pl_byte_at(i + 4) == 112 && pl_byte_at(i + 5) == 41) {
            int64_t digits = i;
            while (digits > start) {
                int64_t b = pl_byte_at(digits - 1);
                if (!((b >= 48 && b <= 57) || b == 45)) {
                    break;
                }
                digits -= 1;
            }
            if (digits == i) {
                return 0;
            }
            if (pl_decimal_valid(digits, i)) {
                return pl_decimal_value(digits, i);
            }
            return 0;
        }
        i += 1;
    }
    return PL_NONE;
}

/* Sweep metadata for one emitted record: compiler-backend-sweep-line-* in
 * record form. */
static void pl_record_sweep(const int64_t *slot, int64_t index) {
    int64_t start = slot[PL_F_START];
    int64_t end = slot[PL_F_END];
    int64_t ms = slot[PL_F_MN_START];
    int64_t mlen = slot[PL_F_MN_LEN];
    int64_t flags = 0;
    int64_t cand = PL_NONE;
    int64_t read = PL_NONE;
    int64_t width;
    int64_t value = 0;
    if (slot[PL_F_LABEL] == 1) {
        flags |= PL_SW_LABEL;
    }
    if (slot[PL_F_OWNED] == 0 && mlen == 4 && pl_byte_at(ms) == 108 &&
        pl_byte_at(ms + 1) == 101 && pl_byte_at(ms + 2) == 97 &&
        pl_byte_at(ms + 3) == 113) {
        flags |= PL_SW_LEAQ;
    }
    if (slot[PL_F_OWNED] == 0 && mlen >= 4 && pl_byte_at(ms) == 112 &&
        pl_byte_at(ms + 1) == 117 && pl_byte_at(ms + 2) == 115 &&
        pl_byte_at(ms + 3) == 104) {
        flags |= PL_SW_PUSH;
    }
    if (slot[PL_F_OWNED] == 0 && mlen >= 3 && pl_byte_at(ms) == 112 &&
        pl_byte_at(ms + 1) == 111 && pl_byte_at(ms + 2) == 112) {
        flags |= PL_SW_POP;
    }
    if (mlen >= 4 && slot[PL_F_OWNED] == 0) {
        int64_t b0 = pl_byte_at(ms);
        int64_t b1 = pl_byte_at(ms + 1);
        int64_t b2 = pl_byte_at(ms + 2);
        if ((b0 == 115 && b1 == 117 && b2 == 98) ||
            (b0 == 97 && b1 == 100 && b2 == 100)) {
            int64_t operand = ms + mlen;
            while (operand < end && pl_byte_at(operand) == 32) {
                operand += 1;
            }
            if (pl_byte_at(operand) == 36 && pl_tail_is_rsp(end)) {
                int64_t comma = pl_find_comma_space(operand, end);
                if (comma > operand + 1 && pl_decimal_valid(operand + 1, comma)) {
                    flags |= PL_SW_TRACKED;
                    flags |= PL_SW_RSP_DST;
                    if (b0 == 115) {
                        flags |= PL_SW_SUBQ;
                    }
                    value = pl_decimal_value(operand + 1, comma);
                }
            }
        }
    }
    if (slot[PL_F_OWNED] == 0 && pl_tail_is_rsp(end) &&
        (flags & PL_SW_TRACKED) == 0) {
        flags |= PL_SW_RSP_DST;
    }
    if (slot[PL_F_OWNED] == 0 && pl_indexed_rsp(start, end)) {
        flags |= PL_SW_FATAL;
    }
    width = pl_access_width(slot);
    if (slot[PL_F_MOVQ] == 1 &&
        pl_memory_base(slot[PL_F_DST_START], slot[PL_F_DST_END]) == 2 &&
        slot[PL_F_DST_KEY] > 0 && (slot[PL_F_SRC_FLAGS] & PL_OP_STACK) == 0) {
        cand = pl_rsp_displacement(slot[PL_F_DST_START], slot[PL_F_DST_END]);
    }
    if (cand == PL_NONE) {
        read = slot[PL_F_OWNED] == 0
                   ? pl_first_rsp_read(start, end)
                   : pl_first_rsp_read(slot[PL_F_SRC_START], slot[PL_F_SRC_END]);
    }
    pl_rec_flags[index] = flags;
    pl_rec_cand[index] = cand;
    pl_rec_read[index] = read;
    pl_rec_width[index] = width;
    pl_rec_value[index] = value;
}

static void pl_push_record(const int64_t *slot) {
    int64_t index = pl_rec_len;
    pl_rec_owned[index] = slot[PL_F_OWNED];
    pl_rec_src_start[index] = slot[PL_F_SRC_START];
    pl_rec_src_end[index] = slot[PL_F_SRC_END];
    pl_rec_dst_start[index] = slot[PL_F_DST_START];
    pl_rec_dst_end[index] = slot[PL_F_DST_END];
    pl_rec_live[index] = 1;
    pl_record_sweep(slot, index);
    pl_rec_len += 1;
    pl_kept += 1;
}

/* compiler-backend-peephole-emit-line-desc-record */
static void pl_emit_record(const int64_t *slot, int64_t prev_abort) {
    if (slot[PL_F_MOVQ] == 1) {
        int64_t src_reg = slot[PL_F_SRC_REG];
        int64_t dst_reg = slot[PL_F_DST_REG];
        int64_t src_key = slot[PL_F_SRC_KEY];
        int64_t dst_key = slot[PL_F_DST_KEY];
        int is_slot = src_key != 0;
        int dst_owns = is_slot && dst_reg >= 0 && pl_owners[dst_reg] == src_key;
        int64_t reuse = (is_slot && !dst_owns && dst_reg >= 0)
                            ? pl_owners_find_reg(src_key, dst_reg)
                            : -1;
        if (dst_owns) {
            pl_elided += 1;
            pl_dropped += 1;
        } else if (reuse >= 0) {
            pl_reused += 1;
            pl_push_record(slot);
            /* The pushed line becomes `movq %rY, DST`, a register source, so it
             * no longer reads the frame slot the sweep would have seen. */
            pl_rec_read[pl_rec_len - 1] = PL_NONE;
        } else {
            pl_push_record(slot);
        }
        pl_owners_transfer(src_reg, dst_reg, src_key, dst_key);
    } else {
        pl_push_record(slot);
        pl_clobber_owners(slot, prev_abort);
    }
}

/* compiler-backend-deadstore-sweep-records! / -sweep-region-records! */
static void pl_sweep_region(void) {
    int64_t delta = 0;
    int sweepable = 1;
    int64_t watermark = PL_NONE;
    int64_t cand_count = 0;
    int64_t read_count = 0;
    int64_t i = 0;
    int64_t k;
    while (sweepable && i < pl_rec_len) {
        int64_t flags = pl_rec_flags[i];
        int64_t cand = pl_rec_cand[i];
        int64_t read = pl_rec_read[i];
        if ((flags & PL_SW_LABEL) != 0) {
            delta = 0;
        } else {
            if ((flags & PL_SW_FATAL) != 0) {
                sweepable = 0;
            }
            if ((flags & PL_SW_LEAQ) != 0 && read != PL_NONE) {
                int64_t address = read - delta;
                if (address < watermark) {
                    watermark = address;
                }
            }
            if (cand != PL_NONE && cand_count < 4096) {
                pl_sweep_cand_pos[cand_count] = i;
                pl_sweep_cand_off[cand_count] = cand - delta;
                cand_count += 1;
            }
            if (cand == PL_NONE && read != PL_NONE && (flags & PL_SW_LEAQ) == 0 &&
                read_count < 4096) {
                pl_sweep_read_lo[read_count] = read - delta;
                pl_sweep_read_hi[read_count] = read - delta + pl_rec_width[i];
                read_count += 1;
            }
            if ((flags & PL_SW_PUSH) != 0) {
                delta += 8;
            }
            if ((flags & PL_SW_POP) != 0) {
                delta -= 8;
            }
            if ((flags & PL_SW_RSP_DST) != 0) {
                if ((flags & PL_SW_TRACKED) != 0) {
                    if ((flags & PL_SW_SUBQ) != 0) {
                        delta += pl_rec_value[i];
                    } else {
                        delta -= pl_rec_value[i];
                    }
                } else {
                    sweepable = 0;
                }
            }
        }
        i += 1;
    }
    if (sweepable && cand_count > 0) {
        for (k = 0; k < cand_count; k += 1) {
            int64_t offset = pl_sweep_cand_off[k];
            int64_t position = pl_sweep_cand_pos[k];
            int64_t r = 0;
            int observed = 0;
            if (offset < watermark) {
                while (!observed && r < read_count) {
                    if (pl_sweep_read_lo[r] < offset + 8 &&
                        offset < pl_sweep_read_hi[r]) {
                        observed = 1;
                    }
                    r += 1;
                }
                if (!observed) {
                    pl_rec_live[position] = 0;
                    pl_swept += 1;
                    pl_kept -= 1;
                }
            }
        }
    }
}

/* compiler-backend-asm-label-def-line? */
static int pl_label_def_line(int64_t start, int64_t end) {
    int64_t limit;
    int64_t i;
    if (end - start < 2) {
        return 0;
    }
    if (pl_byte_at(end - 1) != 58) {
        return 0;
    }
    limit = end - 1;
    i = start;
    while (i < limit) {
        int64_t b = pl_byte_at(i);
        if (b == 32 || b == 9 || b == 58) {
            return 0;
        }
        i += 1;
    }
    return 1;
}

/* compiler-backend-asm-direct-jmp-line? */
static int pl_direct_jmp_line(int64_t start, int64_t end) {
    int64_t operand_start = start + 8;
    int64_t i;
    if (end <= operand_start) {
        return 0;
    }
    if (!(pl_byte_at(start) == 32 && pl_byte_at(start + 1) == 32 &&
          pl_byte_at(start + 2) == 32 && pl_byte_at(start + 3) == 32 &&
          pl_byte_at(start + 4) == 106 && pl_byte_at(start + 5) == 109 &&
          pl_byte_at(start + 6) == 112 && pl_byte_at(start + 7) == 32)) {
        return 0;
    }
    i = operand_start;
    while (i < end) {
        int64_t b = pl_byte_at(i);
        if (b == 32 || b == 9 || b == 42 || b == 37 || b == 40 || b == 44) {
            return 0;
        }
        i += 1;
    }
    return 1;
}

/* compiler-backend-drop-fallthrough-jumps */
static void pl_drop_fallthrough(int64_t start, int64_t stop) {
    int64_t i = start;
    int pending = 0;
    int64_t target_start = 0;
    int64_t target_stop = 0;
    while (i < stop) {
        int64_t end = pl_line_end(i, stop);
        int64_t next_start = end < stop ? end + 1 : end;
        int consumed = 0;
        if (pending) {
            if (pl_label_def_line(i, end)) {
                consumed = 1;
                if (pl_ranges_eq(target_start, target_stop, i, end - 1)) {
                    pl_fallthrough += 1;
                    pending = 0;
                }
            } else {
                pending = 0;
            }
        }
        if (!consumed && pl_direct_jmp_line(i, end)) {
            pending = 1;
            target_start = i + 8;
            target_stop = end;
        }
        i = next_start;
    }
}

/* compiler-backend-peephole-asm-once-records-chunks over one chunk. */
static uint64_t pl_run_chunk(int64_t start, int64_t stop) {
    int64_t i = start;
    int has_pending = 0;
    int64_t prev_abort = 0;
    uint64_t hash = PL_HASH_BASIS;
    pl_rec_len = 0;
    pl_owners_empty();
    pl_drop_fallthrough(start, stop);
    while (i < stop) {
        int64_t end = pl_line_end(i, stop);
        int64_t next_start = end < stop ? end + 1 : end;
        int64_t newline = end < stop ? 1 : 0;
        if (has_pending) {
            int64_t action;
            pl_parse_line(pl_next, i, end, newline == 1);
            action = pl_pair_action(pl_pending, pl_next);
            if (action == 1) {
                pl_rule1 += 1;
                pl_dropped += 1;
                pl_copy_line(pl_pending, pl_next);
            } else if (action == 2) {
                pl_rule2 += 1;
                pl_dropped += 1;
            } else if (action == 3) {
                pl_rule3 += 1;
                pl_emit_record(pl_pending, prev_abort);
                prev_abort = pl_pending[PL_F_ABORT];
                pl_owned_line(pl_pending, pl_pending[PL_F_SRC_START],
                              pl_pending[PL_F_SRC_END], pl_next[PL_F_DST_START],
                              pl_next[PL_F_DST_END], newline);
            } else if (action == 4) {
                pl_rule4 += 1;
                pl_owned_line(pl_pending, pl_next[PL_F_SRC_START],
                              pl_next[PL_F_SRC_END], pl_next[PL_F_DST_START],
                              pl_next[PL_F_DST_END], newline);
            } else {
                pl_emit_record(pl_pending, prev_abort);
                prev_abort = pl_pending[PL_F_ABORT];
                pl_copy_line(pl_pending, pl_next);
            }
        } else {
            has_pending = 1;
            pl_parse_line(pl_pending, i, end, newline == 1);
        }
        i = next_start;
    }
    if (has_pending && !pl_self_move(pl_pending)) {
        pl_emit_record(pl_pending, prev_abort);
    }
    pl_sweep_region();
    hash = pl_mix(hash, pl_rec_len);
    hash = pl_mix(hash, pl_kept);
    hash = pl_mix(hash, pl_dropped);
    hash = pl_mix(hash, pl_rule1);
    hash = pl_mix(hash, pl_rule2);
    hash = pl_mix(hash, pl_rule3);
    hash = pl_mix(hash, pl_rule4);
    hash = pl_mix(hash, pl_elided);
    hash = pl_mix(hash, pl_reused);
    hash = pl_mix(hash, pl_fallthrough);
    return pl_mix(hash, pl_swept);
}

/* A chunk boundary: the first non-space bytes of the line are `.globl`. */
static int pl_globl_line(int64_t start, int64_t end) {
    int64_t i = start;
    while (i < end && pl_byte_at(i) == 32) {
        i += 1;
    }
    return i + 6 <= end && pl_byte_at(i) == 46 && pl_byte_at(i + 1) == 103 &&
           pl_byte_at(i + 2) == 108 && pl_byte_at(i + 3) == 111 &&
           pl_byte_at(i + 4) == 98 && pl_byte_at(i + 5) == 108;
}

static int64_t pl_bench(const char *path, int64_t rounds) {
    int64_t chunks = 0;
    int64_t max_lines = 1;
    int64_t round = 0;
    int64_t start = 0;
    uint64_t acc = PL_HASH_BASIS;
    int64_t i = 0;
    int64_t chunk_begin = 0;
    int64_t lines = 0;

    pl_read_file(path);
    acc = pl_mix(acc, pl_len);
    pl_chunk_start = pl_alloc(pl_len / 16 + 4);
    pl_chunk_end = pl_alloc(pl_len / 16 + 4);
    while (i < pl_len) {
        int64_t end = pl_line_end(i, pl_len);
        int64_t next_start = end < pl_len ? end + 1 : end;
        if (pl_globl_line(i, end) && i > chunk_begin) {
            pl_chunk_start[chunks] = chunk_begin;
            pl_chunk_end[chunks] = i;
            if (lines > max_lines) {
                max_lines = lines;
            }
            chunks += 1;
            chunk_begin = i;
            lines = 0;
        }
        lines += 1;
        i = next_start;
    }
    if (pl_len > chunk_begin) {
        pl_chunk_start[chunks] = chunk_begin;
        pl_chunk_end[chunks] = pl_len;
        if (lines > max_lines) {
            max_lines = lines;
        }
        chunks += 1;
    }
    pl_chunk_count = chunks;

    pl_rec_owned = pl_alloc(max_lines + 2);
    pl_rec_src_start = pl_alloc(max_lines + 2);
    pl_rec_src_end = pl_alloc(max_lines + 2);
    pl_rec_dst_start = pl_alloc(max_lines + 2);
    pl_rec_dst_end = pl_alloc(max_lines + 2);
    pl_rec_flags = pl_alloc(max_lines + 2);
    pl_rec_cand = pl_alloc(max_lines + 2);
    pl_rec_read = pl_alloc(max_lines + 2);
    pl_rec_width = pl_alloc(max_lines + 2);
    pl_rec_value = pl_alloc(max_lines + 2);
    pl_rec_live = pl_alloc(max_lines + 2);
    pl_sweep_cand_pos = pl_alloc(4097);
    pl_sweep_cand_off = pl_alloc(4097);
    pl_sweep_read_lo = pl_alloc(4097);
    pl_sweep_read_hi = pl_alloc(4097);

    while (round < rounds) {
        int64_t step = 0;
        acc = pl_mix(acc, round);
        pl_kept = 0;
        pl_dropped = 0;
        pl_rule1 = 0;
        pl_rule2 = 0;
        pl_rule3 = 0;
        pl_rule4 = 0;
        pl_elided = 0;
        pl_reused = 0;
        pl_fallthrough = 0;
        pl_swept = 0;
        while (step < chunks) {
            int64_t index = start + step;
            if (index >= chunks) {
                index -= chunks;
            }
            acc = pl_mix(acc, (int64_t)pl_run_chunk(pl_chunk_start[index],
                                                    pl_chunk_end[index]));
            step += 1;
        }
        start += 1;
        if (start >= chunks) {
            start = 0;
        }
        round += 1;
    }
    return (int64_t)acc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)pl_bench(path, rounds));
    return 0;
}
