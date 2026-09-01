/* benchmarks/regalloc_greedy/baseline.c - clang C baseline for
 * regalloc_greedy.
 *
 * Equivalent to benchmarks/regalloc_greedy/bench.tl: the TypeLisp compiler's
 * own LLVM-style per-vreg Greedy register allocator (RAGreedy selectOrSplit),
 * run over real live intervals, spill weights, copy hints and clobber points
 * the compiler produced while compiling itself (see README.md for the corpus).
 *
 * Mirrored compiler functions, all in src/compiler_regalloc.tl:
 *   compiler-reg-greedy-combine-spill-weights, compiler-reg-priority-keys!,
 *   compiler-reg-priority-band-value, compiler-reg-block-index-of-point,
 *   compiler-reg-priority-key-weight
 *   compiler-reg-greedy-weight-before? / -merge-run! / -merge-pass! / -sort!
 *   compiler-reg-greedy-heap-better? / -heap-sift-up! / -heap-sift-down! /
 *     -heap-push! / -heap-pop!
 *   compiler-reg-greedy-worklist-seed! / -worklist-run! / -alloc-all! /
 *     -alloc-one! (the RS_* stage machine)
 *   compiler-reg-greedy-var-spans-clobber? / -forbidden-regs / -arg-pref-reg /
 *     -hint-free-reg / -first-free / -reg-free? / -interferer-max /
 *     -interferer-max-capped / -first-evictable / -evict-requeue!
 *   compiler-reg-greedy-occupancy-set-bit! / -clear! / -assign! / -pool-index
 *   compiler-reg-live-union-lower-bound / -segment-hits? / -interferes? /
 *     -refresh-max! / -insert-segment! / -add! / -remove!
 *   compiler-reg-assignment-table-insert / -unassign / -lookup
 *   compiler-reg-interval-seq-overlaps?,
 *     compiler-reg-vars-interfere-segmented-index?
 *   compiler-reg-call-set-in-range?, compiler-reg-segments-span-clobber?
 *   compiler-reg-low-bit-index32-nonzero (the De Bruijn table)
 *   compiler-reg-assignment-table-location-conflicts? (the self-check)
 *
 * The compiler's recursive helpers are recursive here too, exactly as they are
 * in bench.tl.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum here is formed in
 * uint64_t so the C side wraps identically, and every other value in this
 * workload stays far inside 63 bits. The printed decimal is the checksum
 * reinterpreted as a signed 64-bit integer, matching TypeLisp's print of an
 * i64.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define RG_HASH_BASIS 1469598103934665603ULL
#define RG_HASH_PRIME 1099511628211ULL

/* compiler-reg-greedy-integer-pool-for-abi Linux and its caller-saved prefix. */
#define RG_POOL_COUNT 14
#define RG_CALLER_SAVED_COUNT 9
#define RG_POOL_INDEX_CAPACITY 104
#define RG_WORD_BITS 32
#define RG_BAND_SPAN 2097152
#define RG_LOCAL_SPAN 1048576
#define RG_TIE_SPAN 1024
#define RG_WEIGHT_CAP 1073741824
#define RG_EVICT_CAP 4
#define RG_EVICT_INF 35184372088832LL
#define RG_NEG_INF (-1000000000LL)
#define RG_ENTRY_WORDS 3
#define RG_STAGE_NEW 0
#define RG_STAGE_ASSIGN 1
#define RG_STAGE_SPLIT 2
#define RG_STAGE_SPILL 3
#define RG_ID_RAX 0
#define RG_ID_RCX 1
#define RG_ID_RDX 2

/* Parsed corpus tokens and the scratch arrays every per-function pass reuses.
 * File-scope state keeps the allocator functions parameterless, matching how
 * the compiler threads one workspace through a pass. */
static int64_t *rg_tokens;
static int64_t *rg_offsets;
static int64_t *rg_lowbit;
static int64_t *rg_pool_reg;
static int64_t *rg_pool_idx;
static int64_t *rg_seg_lo;
static int64_t *rg_seg_hi;
static int64_t *rg_seg_start;
static int64_t *rg_seg_end;
static int64_t *rg_raw;
static int64_t *rg_key;
static int64_t *rg_hint;
static int64_t *rg_argpref;
static int64_t *rg_param;
static int64_t *rg_group;
static int64_t *rg_present;
static int64_t *rg_kind;
static int64_t *rg_reg;
static int64_t *rg_primary;
static int64_t *rg_secondary;
static int64_t *rg_pending;
static int64_t *rg_evict;
static int64_t *rg_stage;
static int64_t *rg_order;
static int64_t *rg_sortbuf;
static int64_t *rg_heap;
static int64_t *rg_occ;
static int64_t *rg_union;
static int64_t *rg_ucount;
static int64_t *rg_ucoarse;
static int64_t *rg_callbits;
static int64_t *rg_divbits;
static int64_t *rg_shiftbits;
static int64_t *rg_forb;
static int64_t *rg_residents;

/* Per-function view of the corpus, set by rg_load_function before it runs. */
static int64_t rg_vars;
static int64_t rg_nblocks;
static int64_t rg_ncand;
static int64_t rg_nrows;
static int64_t rg_points_base;
static int64_t rg_cand_base;
static int64_t rg_wordcount = 1;
static int64_t rg_clobber_words = 1;
static int64_t rg_ustride = 3;
static int64_t rg_heap_len;
static int64_t rg_forb_count;
static int64_t rg_hint_start;
static int64_t rg_assigned;
static int64_t rg_spilled;
static int64_t rg_splits;
static int64_t rg_evictions;
static int64_t rg_spans_seen;
/* 1 only on the first round: the conflict verification is a per-function
 * property, so checking each function once per run is what the self-check
 * needs, and the later rounds measure the allocator alone. */
static int64_t rg_verify;

static uint64_t rg_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * RG_HASH_PRIME;
}

static int64_t *rg_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static char *rg_read_file(const char *path, int64_t *length) {
    FILE *handle = fopen(path, "rb");
    char *text;
    long size;
    if (!handle) {
        abort();
    }
    if (fseek(handle, 0, SEEK_END) != 0) {
        abort();
    }
    size = ftell(handle);
    if (size < 0 || fseek(handle, 0, SEEK_SET) != 0) {
        abort();
    }
    text = (char *)malloc((size_t)size + 1);
    if (!text) {
        abort();
    }
    if (fread(text, 1, (size_t)size, handle) != (size_t)size) {
        abort();
    }
    text[size] = '\0';
    fclose(handle);
    *length = (int64_t)size;
    return text;
}

static int64_t rg_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int rg_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t rg_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = rg_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && rg_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (rg_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (rg_digit(rg_byte_at(text, n, i))) {
                value = value * 10 + (rg_byte_at(text, n, i) - 48);
                i += 1;
            }
            out[count] = negative ? -value : value;
            count += 1;
        } else {
            i += 1;
        }
    }
    return count;
}

/* compiler-reg-low-bit-index32-nonzero: the De Bruijn multiply-and-look-up
 * index of the lowest set bit of a 32-bit word, with the zero guard dropped
 * exactly as the compiler's bit walks do. */
static int64_t rg_low_bit_nz(int64_t bits) {
    int64_t isolated = bits & (0 - bits);
    int64_t slot = ((isolated * 125613361) & 4294967295LL) >> 27;
    return rg_lowbit[slot];
}

static void rg_lowbit_init(void) {
    static const int64_t table[32] = {
        0,  1,  28, 2,  29, 14, 24, 3,  30, 22, 20, 15, 25, 17, 4, 8,
        31, 27, 13, 23, 21, 19, 16, 7,  26, 12, 18, 6,  11, 5,  10, 9};
    int64_t i;
    for (i = 0; i < 32; i += 1) {
        rg_lowbit[i] = table[i];
    }
}

/* compiler-reg-greedy-pool-index-build / -pool-index: canonical register id ->
 * pool slot, first occurrence wins, -1 when the register is not in the pool. */
static void rg_pool_init(void) {
    static const int64_t pool[RG_POOL_COUNT] = {RG_ID_RAX, 6,  7,  9,  RG_ID_RCX,
                                                RG_ID_RDX, 10, 11, 8,  12,
                                                13,        14, 15, 3};
    int64_t i;
    for (i = 0; i < RG_POOL_INDEX_CAPACITY; i += 1) {
        rg_pool_idx[i] = -1;
    }
    for (i = 0; i < RG_POOL_COUNT; i += 1) {
        rg_pool_reg[i] = pool[i];
    }
    for (i = 0; i < RG_POOL_COUNT; i += 1) {
        int64_t key = rg_pool_reg[i];
        if (key >= 0 && key < RG_POOL_INDEX_CAPACITY && rg_pool_idx[key] < 0) {
            rg_pool_idx[key] = i;
        }
    }
}

static int64_t rg_pool_index(int64_t reg) {
    if (reg >= 0 && reg < RG_POOL_INDEX_CAPACITY) {
        return rg_pool_idx[reg];
    }
    return -1;
}

/* compiler-reg-id-seq-contains? over the per-root forbidden register set. */
static int rg_forbidden(int64_t reg) {
    int64_t i = 0;
    int found = 0;
    while (i < rg_forb_count && !found) {
        if (rg_forb[i] == reg) {
            found = 1;
        }
        i += 1;
    }
    return found;
}

/* compiler-reg-id-seq-contains? over `hint-regs`: the whole pool, or -- for a
 * call-spanning or parameter root -- only the callee-saved suffix. */
static int rg_hint_allowed(int64_t reg) {
    int64_t i = rg_hint_start;
    int found = 0;
    while (i < RG_POOL_COUNT && !found) {
        if (rg_pool_reg[i] == reg) {
            found = 1;
        }
        i += 1;
    }
    return found;
}

/* compiler-reg-call-word-in-range? */
static int rg_call_word_in_range(int64_t bits, int64_t base, int64_t start,
                                 int64_t end) {
    if (bits == 0) {
        return 0;
    }
    {
        int64_t c = base + rg_low_bit_nz(bits);
        if (start < c && c < end) {
            return 1;
        }
        return rg_call_word_in_range(bits & (bits - 1), base, start, end);
    }
}

static int rg_call_set_in_range_words(const int64_t *set, int64_t start,
                                      int64_t end, int64_t word_index,
                                      int64_t last_word) {
    if (word_index > last_word) {
        return 0;
    }
    if (rg_call_word_in_range(set[word_index], word_index * RG_WORD_BITS, start,
                              end)) {
        return 1;
    }
    return rg_call_set_in_range_words(set, start, end, word_index + 1,
                                      last_word);
}

/* compiler-reg-call-set-in-range?: only the words holding positions inside
 * (start, end) can answer yes, so the scan starts and stops at those words. */
static int rg_call_set_in_range(const int64_t *set, int64_t start,
                                int64_t end) {
    int64_t last_pos = end - 1;
    int64_t first_pos = start + 1 < 0 ? 0 : start + 1;
    int64_t first_word;
    int64_t raw_last_word;
    int64_t last_word;
    if (first_pos > last_pos) {
        return 0;
    }
    first_word = first_pos >> 5;
    raw_last_word = last_pos >> 5;
    last_word =
        raw_last_word >= rg_clobber_words ? rg_clobber_words - 1 : raw_last_word;
    if (first_word > last_word) {
        return 0;
    }
    return rg_call_set_in_range_words(set, start, end, first_word, last_word);
}

/* compiler-reg-segments-span-clobber?: a clobber at the hull start is that
 * value's own definition, so only that segment keeps the exclusive start. */
static int rg_segments_span_clobber(int64_t var, const int64_t *set,
                                    int64_t hull_start) {
    int64_t index = rg_seg_lo[var];
    int64_t limit = rg_seg_hi[var];
    int hit = 0;
    while (index < limit && !hit) {
        int64_t segment_start = rg_seg_start[index];
        int64_t low = segment_start == hull_start ? segment_start
                                                  : segment_start - 1;
        if (rg_call_set_in_range(set, low, rg_seg_end[index])) {
            hit = 1;
        }
        index += 1;
    }
    return hit;
}

/* compiler-reg-greedy-var-spans-clobber?: the coarse hull gate, then the
 * segment-aware answer (a hull hole is genuine deadness). */
static int rg_var_spans_clobber(int64_t var, const int64_t *set) {
    int64_t lo = rg_seg_lo[var];
    int64_t hi = rg_seg_hi[var];
    int64_t hull_start;
    int64_t hull_end;
    if (lo == hi) {
        return 1;
    }
    hull_start = rg_seg_start[lo];
    hull_end = rg_seg_end[hi - 1];
    return rg_call_set_in_range(set, hull_start, hull_end) &&
           rg_segments_span_clobber(var, set, hull_start);
}

/* compiler-reg-interval-seq-overlaps?, over compiler-reg-interval-overlap?'s
 * boundary rule: half-open, except that a touch at point 0 counts as overlap
 * (a parameter's home was written in the prologue). Both inputs ascend by
 * start, so the scan retires whichever segment ends first. */
static int rg_seq_overlaps(int64_t left_lo, int64_t left_hi, int64_t right_lo,
                           int64_t right_hi) {
    int64_t left_index = left_lo;
    int64_t right_index = right_lo;
    int overlap = 0;
    while (left_index < left_hi && right_index < right_hi && !overlap) {
        int64_t left_start = rg_seg_start[left_index];
        int64_t left_end = rg_seg_end[left_index];
        int64_t right_start = rg_seg_start[right_index];
        int64_t right_end = rg_seg_end[right_index];
        if (left_end <= right_start && right_start != 0) {
            left_index += 1;
        } else if (right_end <= left_start && left_start != 0) {
            right_index += 1;
        } else {
            overlap = 1;
        }
    }
    return overlap;
}

/* compiler-reg-vars-interfere-segmented-index?: per-var segments when both
 * sides have them. compiler-reg-vars-interfere-index? is the fallback, and a
 * var with no segments has no coarse interval either, so it answers true. */
static int rg_vars_interfere(int64_t left, int64_t right) {
    int64_t left_lo;
    int64_t left_hi;
    int64_t right_lo;
    int64_t right_hi;
    if (left == right) {
        return 1;
    }
    left_lo = rg_seg_lo[left];
    left_hi = rg_seg_hi[left];
    right_lo = rg_seg_lo[right];
    right_hi = rg_seg_hi[right];
    if (left_lo != left_hi && right_lo != right_hi) {
        return rg_seq_overlaps(left_lo, left_hi, right_lo, right_hi);
    }
    return 1;
}

/* compiler-reg-live-union-effective-start */
static int64_t rg_effective_start(int64_t start) {
    return start == 0 ? RG_NEG_INF : start;
}

/* compiler-reg-live-union-lower-bound */
static int64_t rg_union_lower_bound(int64_t reg_index, int64_t count,
                                    int64_t bound) {
    int64_t base = reg_index * rg_ustride;
    int64_t lo = 0;
    int64_t hi = count;
    while (lo < hi) {
        int64_t mid = lo + ((hi - lo) >> 1);
        if (rg_union[base + mid * RG_ENTRY_WORDS] < bound) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

/* compiler-reg-live-union-segment-hits?: one binary search plus one load. */
static int rg_union_segment_hits(int64_t reg_index, int64_t count,
                                 int64_t es_start, int64_t end) {
    int64_t above = rg_union_lower_bound(reg_index, count, end);
    if (above == 0) {
        return 0;
    }
    return rg_union[reg_index * rg_ustride + (above - 1) * RG_ENTRY_WORDS + 2] >
           es_start;
}

/* compiler-reg-live-union-interferes? */
static int rg_union_interferes(int64_t reg_index, int64_t lo, int64_t hi) {
    int64_t count = rg_ucount[reg_index];
    int64_t index = lo;
    int hit = 0;
    while (index < hi && !hit) {
        if (rg_union_segment_hits(reg_index, count,
                                  rg_effective_start(rg_seg_start[index]),
                                  rg_seg_end[index])) {
            hit = 1;
        }
        index += 1;
    }
    return hit;
}

/* compiler-reg-live-union-refresh-max! */
static void rg_union_refresh_max(int64_t reg_index, int64_t count,
                                 int64_t from) {
    int64_t base = reg_index * rg_ustride;
    int64_t index = from < 0 ? 0 : from;
    int64_t running =
        index > 0 ? rg_union[base + (index - 1) * RG_ENTRY_WORDS + 2]
                  : RG_NEG_INF;
    while (index < count) {
        int64_t at = base + index * RG_ENTRY_WORDS;
        int64_t end = rg_union[at + 1];
        if (end > running) {
            running = end;
        }
        rg_union[at + 2] = running;
        index += 1;
    }
}

/* compiler-reg-live-union-insert-segment! */
static void rg_union_insert_segment(int64_t reg_index, int64_t es_start,
                                    int64_t end) {
    int64_t base = reg_index * rg_ustride;
    int64_t count = rg_ucount[reg_index];
    int64_t at = rg_union_lower_bound(reg_index, count, es_start);
    int64_t cursor = count * RG_ENTRY_WORDS - 1;
    int64_t floor = at * RG_ENTRY_WORDS;
    while (cursor >= floor) {
        rg_union[base + cursor + RG_ENTRY_WORDS] = rg_union[base + cursor];
        cursor -= 1;
    }
    rg_union[base + floor] = es_start;
    rg_union[base + floor + 1] = end;
    rg_ucount[reg_index] = count + 1;
    rg_union_refresh_max(reg_index, count + 1, at);
}

/* compiler-reg-live-union-add! */
static void rg_union_add(int64_t reg_index, int64_t var) {
    int64_t lo = rg_seg_lo[var];
    int64_t hi = rg_seg_hi[var];
    int64_t index = lo;
    if (lo == hi) {
        rg_ucoarse[reg_index] += 1;
        return;
    }
    while (index < hi) {
        rg_union_insert_segment(reg_index,
                                rg_effective_start(rg_seg_start[index]),
                                rg_seg_end[index]);
        index += 1;
    }
}

/* compiler-reg-live-union-remove!: both sides ascend in effective start, so
 * one merge pass compacts out exactly one entry per segment. */
static void rg_union_remove(int64_t reg_index, int64_t var) {
    int64_t lo = rg_seg_lo[var];
    int64_t hi = rg_seg_hi[var];
    int64_t base;
    int64_t count;
    int64_t read = 0;
    int64_t write = 0;
    int64_t seg_index;
    int64_t first_drop;
    if (lo == hi) {
        rg_ucoarse[reg_index] -= 1;
        return;
    }
    base = reg_index * rg_ustride;
    count = rg_ucount[reg_index];
    seg_index = lo;
    first_drop = count;
    while (read < count) {
        int64_t from = base + read * RG_ENTRY_WORDS;
        int64_t to = base + write * RG_ENTRY_WORDS;
        int matched = 0;
        if (seg_index < hi) {
            matched =
                rg_union[from] == rg_effective_start(rg_seg_start[seg_index]) &&
                rg_union[from + 1] == rg_seg_end[seg_index];
        }
        if (matched) {
            if (write < first_drop) {
                first_drop = write;
            }
            seg_index += 1;
        } else {
            if (from != to) {
                rg_union[to] = rg_union[from];
                rg_union[to + 1] = rg_union[from + 1];
            }
            write += 1;
        }
        read += 1;
    }
    rg_ucount[reg_index] = write;
    rg_union_refresh_max(reg_index, write, first_drop);
}

/* compiler-reg-greedy-occupancy-set-bit!: the union mirrors the bitset
 * exactly, so it is only touched when this call actually flips the bit. */
static void rg_occupancy_set_bit(int64_t reg_index, int64_t var, int present) {
    int64_t word_index;
    int64_t flat_index;
    int64_t mask;
    int64_t old;
    int was_set;
    if (reg_index < 0 || var < 0 || var >= rg_vars) {
        return;
    }
    word_index = var >> 5;
    if (word_index >= rg_wordcount) {
        return;
    }
    flat_index = reg_index * rg_wordcount + word_index;
    mask = (int64_t)1 << (var & 31);
    old = rg_occ[flat_index];
    was_set = (old & mask) != 0;
    if (present) {
        if (!was_set) {
            rg_union_add(reg_index, var);
        }
    } else if (was_set) {
        rg_union_remove(reg_index, var);
    }
    rg_occ[flat_index] = present ? (old | mask) : (old & (mask ^ -1));
}

/* compiler-reg-greedy-occupancy-clear! */
static void rg_occupancy_clear(int64_t var) {
    int64_t first;
    int64_t second;
    if (var < 0 || var >= rg_vars) {
        return;
    }
    first = rg_primary[var];
    second = rg_secondary[var];
    rg_occupancy_set_bit(first, var, 0);
    if (second >= 0 && first != second) {
        rg_occupancy_set_bit(second, var, 0);
    }
    rg_primary[var] = -1;
    rg_secondary[var] = -1;
}

/* compiler-reg-greedy-occupancy-assign! */
static void rg_occupancy_assign(int64_t var, int64_t first, int64_t second) {
    if (var < 0 || var >= rg_vars) {
        return;
    }
    rg_occupancy_clear(var);
    rg_primary[var] = first;
    rg_secondary[var] = second;
    rg_occupancy_set_bit(first, var, 1);
    if (second >= 0 && first != second) {
        rg_occupancy_set_bit(second, var, 1);
    }
}

/* compiler-reg-greedy-assignment-register! / -spill! / -unassign! over
 * compiler-reg-assignment-table-insert / -unassign. */
static void rg_assign_register(int64_t var, int64_t reg_index) {
    rg_occupancy_assign(var, reg_index, -1);
    rg_present[var] = 1;
    rg_kind[var] = 1;
    rg_reg[var] = rg_pool_reg[reg_index];
}

static void rg_assign_spill(int64_t var) {
    rg_occupancy_clear(var);
    rg_present[var] = 1;
    rg_kind[var] = 2;
    rg_reg[var] = -1;
}

static void rg_assign_unassign(int64_t var) {
    rg_occupancy_clear(var);
    rg_present[var] = 0;
    rg_kind[var] = 0;
    rg_reg[var] = -1;
}

/* compiler-reg-priority-key-weight */
static int64_t rg_key_weight(int64_t key) {
    return key < 0 ? key : key / RG_BAND_SPAN;
}

/* compiler-reg-greedy-interferer-max */
static int64_t rg_interferer_max(int64_t var, int64_t reg_index,
                                 int64_t word_index, int64_t acc) {
    int64_t bits;
    int64_t best = acc;
    if (word_index >= rg_wordcount) {
        return acc;
    }
    bits = rg_occ[reg_index * rg_wordcount + word_index];
    while (bits != 0) {
        int64_t other = word_index * RG_WORD_BITS + rg_low_bit_nz(bits);
        if (other != var && rg_vars_interfere(var, other)) {
            int64_t weight = other < rg_vars ? rg_key[other] : 0;
            if (weight > best) {
                best = weight;
            }
        }
        bits &= bits - 1;
    }
    return rg_interferer_max(var, reg_index, word_index + 1, best);
}

/* compiler-reg-greedy-reg-free?: the union answers when the candidate has
 * segments, no resident of this register lacks them, and the candidate is not
 * itself a resident; otherwise the per-resident scan is the backstop. */
static int rg_reg_free(int64_t var, int64_t reg_index) {
    int64_t lo = rg_seg_lo[var];
    int64_t hi = rg_seg_hi[var];
    if (lo != hi && rg_ucoarse[reg_index] == 0 &&
        rg_primary[var] != reg_index && rg_secondary[var] != reg_index) {
        return !rg_union_interferes(reg_index, lo, hi);
    }
    return rg_interferer_max(var, reg_index, 0, -1) == -1;
}

/* compiler-reg-greedy-first-free */
static int64_t rg_first_free(int64_t var, int64_t ridx, int64_t rcount) {
    if (ridx >= rcount) {
        return -1;
    }
    if (!rg_forbidden(rg_pool_reg[ridx]) && rg_reg_free(var, ridx)) {
        return ridx;
    }
    return rg_first_free(var, ridx + 1, rcount);
}

/* compiler-reg-greedy-interferer-max-capped: cascade-aware, so a register
 * pinned by an over-cap resident answers evict-inf. */
static int64_t rg_interferer_max_capped(int64_t var, int64_t reg_index,
                                        int64_t word_index, int64_t acc) {
    int64_t bits;
    int64_t best = acc;
    if (word_index >= rg_wordcount) {
        return acc;
    }
    bits = rg_occ[reg_index * rg_wordcount + word_index];
    while (bits != 0 && best < RG_EVICT_INF) {
        int64_t other = word_index * RG_WORD_BITS + rg_low_bit_nz(bits);
        if (other != var && rg_vars_interfere(var, other)) {
            int64_t ec = other < rg_vars ? rg_evict[other] : 0;
            int64_t weight = other < rg_vars ? rg_key_weight(rg_key[other]) : 0;
            if (ec >= RG_EVICT_CAP) {
                best = RG_EVICT_INF;
            } else if (weight > best) {
                best = weight;
            }
        }
        bits &= bits - 1;
    }
    if (best >= RG_EVICT_INF) {
        return best;
    }
    return rg_interferer_max_capped(var, reg_index, word_index + 1, best);
}

/* compiler-reg-greedy-first-evictable */
static int64_t rg_first_evictable(int64_t var, int64_t weight, int64_t ridx,
                                  int64_t rcount) {
    int64_t m;
    if (ridx >= rcount) {
        return -1;
    }
    m = rg_interferer_max_capped(var, ridx, 0, -1);
    if (!rg_forbidden(rg_pool_reg[ridx]) && m >= 0 && m < weight) {
        return ridx;
    }
    return rg_first_evictable(var, weight, ridx + 1, rcount);
}

/* compiler-reg-greedy-heap-*: a binary max-heap over (weight desc, var asc). */
static int rg_heap_better(int64_t a, int64_t b) {
    int64_t wa = a < rg_vars ? rg_key[a] : 0;
    int64_t wb = b < rg_vars ? rg_key[b] : 0;
    if (wa > wb) {
        return 1;
    }
    if (wa == wb) {
        return a < b;
    }
    return 0;
}

static void rg_heap_swap(int64_t a, int64_t b) {
    int64_t t = rg_heap[a];
    rg_heap[a] = rg_heap[b];
    rg_heap[b] = t;
}

static void rg_heap_sift_up(int64_t index) {
    int64_t parent;
    if (index <= 0) {
        return;
    }
    parent = (index - 1) >> 1;
    if (rg_heap_better(rg_heap[index], rg_heap[parent])) {
        rg_heap_swap(index, parent);
        rg_heap_sift_up(parent);
    }
}

static void rg_heap_sift_down(int64_t len, int64_t index) {
    int64_t left = index * 2 + 1;
    int64_t right = index * 2 + 2;
    int64_t best;
    int64_t best2;
    if (left >= len) {
        return;
    }
    best = rg_heap_better(rg_heap[left], rg_heap[index]) ? left : index;
    best2 = (right < len && rg_heap_better(rg_heap[right], rg_heap[best]))
                ? right
                : best;
    if (best2 == index) {
        return;
    }
    rg_heap_swap(index, best2);
    rg_heap_sift_down(len, best2);
}

static void rg_heap_push(int64_t v) {
    int64_t index = rg_heap_len;
    rg_heap[index] = v;
    rg_heap_len = index + 1;
    rg_heap_sift_up(index);
}

/* The pending array stays authoritative for membership: entries it no longer
 * marks are lazily discarded on pop, so evict-requeue needs no decrease-key. */
static int64_t rg_heap_pop(void) {
    int64_t top;
    int64_t last_index;
    if (rg_heap_len <= 0) {
        return -1;
    }
    top = rg_heap[0];
    last_index = rg_heap_len - 1;
    rg_heap[0] = rg_heap[last_index];
    rg_heap_len = last_index;
    if (last_index > 0) {
        rg_heap_sift_down(last_index, 0);
    }
    if (top >= 0 && top < rg_vars && rg_pending[top] == 1) {
        return top;
    }
    return rg_heap_pop();
}

/* compiler-reg-greedy-evict-requeue! */
static void rg_evict_requeue(int64_t var, int64_t reg_index,
                             int64_t word_index) {
    int64_t bits;
    if (word_index >= rg_wordcount) {
        return;
    }
    bits = rg_occ[reg_index * rg_wordcount + word_index];
    while (bits != 0) {
        int64_t other = word_index * RG_WORD_BITS + rg_low_bit_nz(bits);
        if (other != var && rg_vars_interfere(var, other)) {
            rg_assign_unassign(other);
            if (other < rg_vars) {
                rg_pending[other] = 1;
                rg_heap_push(other);
                rg_evict[other] += 1;
            }
            rg_evictions += 1;
        }
        bits &= bits - 1;
    }
    rg_evict_requeue(var, reg_index, word_index + 1);
}

/* compiler-reg-greedy-arg-pref-reg */
static int64_t rg_arg_pref_reg(int64_t var, int csr_only) {
    int64_t idx;
    if (csr_only) {
        return -1;
    }
    idx = rg_argpref[var];
    if (idx < 0 || idx >= RG_POOL_COUNT) {
        return -1;
    }
    if (!rg_forbidden(rg_pool_reg[idx]) && rg_reg_free(var, idx)) {
        return idx;
    }
    return -1;
}

/* compiler-reg-greedy-hint-free-reg */
static int64_t rg_hint_free_reg(int64_t var) {
    int64_t nb = rg_hint[var];
    int64_t r;
    int64_t reg_index;
    if (nb < 0 || nb >= rg_vars) {
        return -1;
    }
    if (rg_present[nb] != 1 || rg_kind[nb] != 1) {
        return -1;
    }
    r = rg_reg[nb];
    reg_index = rg_pool_index(r);
    if (reg_index >= 0 && !rg_forbidden(r) && rg_hint_allowed(r) &&
        rg_reg_free(var, reg_index)) {
        return reg_index;
    }
    return -1;
}

/* compiler-reg-greedy-alloc-one!: allocate one root and return its terminal
 * RS_* stage. */
static int64_t rg_alloc_one(int64_t var) {
    int spans_call;
    int spans_div;
    int spans_shift;
    int is_param;
    int csr_only;
    int64_t start_idx;
    int64_t pref;
    int64_t hint;
    int64_t chosen;
    int64_t freed;
    int64_t weight;
    int64_t ev;
    if (rg_present[var] == 1 || rg_group[var] == 1) {
        return RG_STAGE_NEW;
    }
    spans_call = rg_var_spans_clobber(var, rg_callbits);
    spans_div = rg_var_spans_clobber(var, rg_divbits);
    spans_shift = rg_var_spans_clobber(var, rg_shiftbits);
    is_param = rg_param[var] == 1;
    csr_only = spans_call || is_param;
    start_idx = csr_only ? RG_CALLER_SAVED_COUNT : 0;
    rg_hint_start = start_idx;
    rg_forb_count = 0;
    if (!csr_only) {
        if (spans_shift) {
            rg_forb[rg_forb_count] = RG_ID_RCX;
            rg_forb_count += 1;
        }
        if (spans_div) {
            rg_forb[rg_forb_count] = RG_ID_RAX;
            rg_forb_count += 1;
            rg_forb[rg_forb_count] = RG_ID_RDX;
            rg_forb_count += 1;
        }
    }
    pref = rg_arg_pref_reg(var, csr_only);
    hint = rg_hint_free_reg(var);
    chosen = pref >= 0 ? pref : hint;
    if (chosen >= 0) {
        rg_assign_register(var, chosen);
        rg_assigned += 1;
        return RG_STAGE_ASSIGN;
    }
    freed = rg_first_free(var, start_idx, RG_POOL_COUNT);
    if (freed >= 0) {
        rg_assign_register(var, freed);
        rg_assigned += 1;
        return RG_STAGE_ASSIGN;
    }
    weight = rg_key_weight(rg_key[var]);
    ev = rg_first_evictable(var, weight, start_idx, RG_POOL_COUNT);
    if (ev >= 0) {
        rg_evict_requeue(var, ev, 0);
        rg_assign_register(var, ev);
        rg_assigned += 1;
        return RG_STAGE_ASSIGN;
    }
    rg_assign_spill(var);
    rg_spilled += 1;
    if (rg_seg_lo[var] != rg_seg_hi[var]) {
        rg_splits += 1;
        return RG_STAGE_SPLIT;
    }
    return RG_STAGE_SPILL;
}

/* compiler-reg-greedy-worklist-seed! */
static void rg_worklist_seed(int64_t i, int64_t count) {
    int64_t v;
    if (i >= count) {
        return;
    }
    v = rg_order[i];
    if (v >= 0 && v < rg_vars) {
        rg_pending[v] = 1;
        rg_heap_push(v);
    }
    rg_worklist_seed(i + 1, count);
}

/* compiler-reg-greedy-worklist-run! */
static void rg_worklist_run(void) {
    int64_t v = rg_heap_pop();
    if (v < 0) {
        return;
    }
    rg_pending[v] = 0;
    rg_stage[v] = rg_alloc_one(v);
    rg_worklist_run();
}

/* compiler-reg-greedy-weight-before? and the stable bottom-up merge sort. */
static int rg_weight_before(int64_t a, int64_t b) {
    int64_t wa = a < rg_vars ? rg_key[a] : 0;
    int64_t wb = b < rg_vars ? rg_key[b] : 0;
    if (wa > wb) {
        return 1;
    }
    if (wa < wb) {
        return 0;
    }
    return a < b;
}

/* Take from the right run only when its head is STRICTLY before the left head;
 * the tie goes left, which is what makes the merge stable. */
static void rg_merge_run(int from_order, int64_t lo, int64_t mid, int64_t hi) {
    int64_t i = lo;
    int64_t j = mid;
    int64_t k = lo;
    while (k < hi) {
        int64_t left = 0;
        int64_t right = 0;
        int take_right;
        if (i < mid) {
            left = from_order ? rg_order[i] : rg_sortbuf[i];
        }
        if (j < hi) {
            right = from_order ? rg_order[j] : rg_sortbuf[j];
        }
        take_right = j < hi && (i >= mid || rg_weight_before(right, left));
        if (take_right) {
            if (from_order) {
                rg_sortbuf[k] = right;
            } else {
                rg_order[k] = right;
            }
            j += 1;
        } else {
            if (from_order) {
                rg_sortbuf[k] = left;
            } else {
                rg_order[k] = left;
            }
            i += 1;
        }
        k += 1;
    }
}

static void rg_merge_pass(int from_order, int64_t count, int64_t width) {
    int64_t lo = 0;
    while (lo < count) {
        int64_t mid = lo + width < count ? lo + width : count;
        int64_t hi = lo + width + width < count ? lo + width + width : count;
        rg_merge_run(from_order, lo, mid, hi);
        lo = hi;
    }
}

static void rg_sort(int64_t count) {
    int64_t width = 1;
    int flipped = 0;
    if (count < 2) {
        return;
    }
    while (width < count) {
        rg_merge_pass(!flipped, count, width);
        flipped = !flipped;
        width += width;
    }
    if (flipped) {
        int64_t i;
        for (i = 0; i < count; i += 1) {
            rg_order[i] = rg_sortbuf[i];
        }
    }
}

/* compiler-reg-block-index-of-point */
static int64_t rg_block_index_of_point(int64_t point) {
    int64_t lo = 0;
    int64_t hi = rg_nblocks - 1;
    int64_t best = 0;
    while (lo <= hi) {
        int64_t mid = (lo + hi) >> 1;
        if (rg_tokens[rg_points_base + mid] <= point) {
            best = mid;
            lo = mid + 1;
        } else {
            hi = mid - 1;
        }
    }
    return best;
}

/* compiler-reg-priority-band-value */
static int64_t rg_priority_band_value(int64_t var) {
    int64_t lo = rg_seg_lo[var];
    int64_t hi = rg_seg_hi[var];
    int64_t s;
    int64_t e;
    if (rg_nblocks < 1 || lo == hi) {
        return RG_BAND_SPAN - 1;
    }
    s = rg_seg_start[lo];
    e = rg_seg_end[hi - 1];
    if (rg_block_index_of_point(s) == rg_block_index_of_point(e)) {
        int64_t limit = RG_LOCAL_SPAN - 1;
        return limit - (s > limit ? limit : s);
    }
    return RG_BAND_SPAN - 1;
}

/* compiler-reg-greedy-combine-spill-weights (with the remat discount dropped,
 * so the discounted input equals the raw one) then compiler-reg-priority-keys!.
 */
static void rg_build_keys(void) {
    int64_t max_raw = 0;
    int64_t v;
    for (v = 0; v < rg_vars; v += 1) {
        if (rg_raw[v] > max_raw) {
            max_raw = rg_raw[v];
        }
    }
    for (v = 0; v < rg_vars; v += 1) {
        int64_t r = rg_raw[v];
        int64_t d = r > RG_WEIGHT_CAP ? RG_WEIGHT_CAP : r;
        int64_t tie = 0;
        if (max_raw != 0) {
            int64_t scaled = (r * RG_TIE_SPAN) / (max_raw + 1);
            tie = scaled >= RG_TIE_SPAN ? RG_TIE_SPAN - 1 : scaled;
        }
        rg_key[v] = d * RG_TIE_SPAN + tie;
    }
    for (v = 0; v < rg_vars; v += 1) {
        rg_key[v] = rg_key[v] * RG_BAND_SPAN + rg_priority_band_value(v);
    }
}

/* compiler-reg-assignment-table-location-conflicts?, run over the finished
 * plan: no two vars holding one register may have overlapping segments. */
static int64_t rg_count_conflicts(void) {
    int64_t conflicts = 0;
    int64_t reg_index;
    for (reg_index = 0; reg_index < RG_POOL_COUNT; reg_index += 1) {
        int64_t count = 0;
        int64_t word_index;
        int64_t a;
        for (word_index = 0; word_index < rg_wordcount; word_index += 1) {
            int64_t bits = rg_occ[reg_index * rg_wordcount + word_index];
            while (bits != 0) {
                rg_residents[count] =
                    word_index * RG_WORD_BITS + rg_low_bit_nz(bits);
                count += 1;
                bits &= bits - 1;
            }
        }
        for (a = 0; a < count; a += 1) {
            int64_t b;
            for (b = a + 1; b < count; b += 1) {
                if (rg_vars_interfere(rg_residents[a], rg_residents[b])) {
                    conflicts += 1;
                }
            }
        }
    }
    return conflicts;
}

/* Read one function's record out of the token tape into the reusable arrays. */
static void rg_load_function(int64_t offset) {
    int64_t ncall = rg_tokens[offset + 3];
    int64_t ndiv = rg_tokens[offset + 4];
    int64_t nshift = rg_tokens[offset + 5];
    int64_t cursor;
    int64_t fill = 0;
    int64_t v;
    int64_t i;

    rg_vars = rg_tokens[offset];
    rg_nblocks = rg_tokens[offset + 1];
    rg_ncand = rg_tokens[offset + 2];
    rg_nrows = rg_tokens[offset + 7];
    rg_points_base = offset + 8;
    rg_cand_base = rg_points_base + rg_nblocks + 1;
    rg_wordcount = (rg_vars + 31) >> 5;
    rg_clobber_words = (rg_tokens[rg_points_base + rg_nblocks] >> 5) + 1;

    for (v = 0; v < rg_vars; v += 1) {
        rg_seg_lo[v] = 0;
        rg_seg_hi[v] = 0;
        rg_raw[v] = 0;
        rg_key[v] = 0;
        rg_hint[v] = -1;
        rg_argpref[v] = -1;
        rg_param[v] = 0;
        rg_group[v] = 0;
        rg_present[v] = 0;
        rg_kind[v] = 0;
        rg_reg[v] = -1;
        rg_primary[v] = -1;
        rg_secondary[v] = -1;
        rg_pending[v] = 0;
        rg_evict[v] = 0;
        rg_stage[v] = 0;
    }
    for (i = 0; i < RG_POOL_COUNT * rg_wordcount; i += 1) {
        rg_occ[i] = 0;
    }
    for (i = 0; i < RG_POOL_COUNT; i += 1) {
        rg_ucount[i] = 0;
        rg_ucoarse[i] = 0;
    }
    for (i = 0; i < rg_clobber_words; i += 1) {
        rg_callbits[i] = 0;
        rg_divbits[i] = 0;
        rg_shiftbits[i] = 0;
    }

    cursor = rg_cand_base + rg_ncand;
    for (i = 0; i < ncall; i += 1) {
        int64_t p = rg_tokens[cursor + i];
        rg_callbits[p >> 5] |= (int64_t)1 << (p & 31);
    }
    cursor += ncall;
    for (i = 0; i < ndiv; i += 1) {
        int64_t p = rg_tokens[cursor + i];
        rg_divbits[p >> 5] |= (int64_t)1 << (p & 31);
    }
    cursor += ndiv;
    for (i = 0; i < nshift; i += 1) {
        int64_t p = rg_tokens[cursor + i];
        rg_shiftbits[p >> 5] |= (int64_t)1 << (p & 31);
    }
    cursor += nshift;

    for (i = 0; i < rg_nrows; i += 1) {
        int64_t var = rg_tokens[cursor];
        int64_t k = rg_tokens[cursor + 1];
        int64_t s;
        rg_seg_lo[var] = fill;
        for (s = 0; s < k; s += 1) {
            rg_seg_start[fill] = rg_tokens[cursor + 2 + s * 2];
            rg_seg_end[fill] = rg_tokens[cursor + 3 + s * 2];
            fill += 1;
        }
        rg_seg_hi[var] = fill;
        rg_raw[var] = rg_tokens[cursor + 2 + k * 2];
        rg_hint[var] = rg_tokens[cursor + 3 + k * 2];
        rg_argpref[var] = rg_tokens[cursor + 4 + k * 2];
        rg_param[var] = rg_tokens[cursor + 5 + k * 2];
        cursor += 6 + k * 2;
    }
}

/* One function's greedy allocation: build the priority keys, collect the
 * candidate roots in candidate order, sort them, seed the worklist and run it,
 * then verify and fold the plan. */
static uint64_t rg_run_function(int64_t offset) {
    uint64_t hash = RG_HASH_BASIS;
    int64_t i;
    int64_t spans = 0;
    int64_t conflicts;

    rg_load_function(offset);
    rg_build_keys();
    rg_assigned = 0;
    rg_spilled = 0;
    rg_splits = 0;
    rg_evictions = 0;
    rg_heap_len = 0;
    for (i = 0; i < rg_ncand; i += 1) {
        rg_order[i] = rg_tokens[rg_cand_base + i];
    }
    rg_sort(rg_ncand);
    rg_worklist_seed(0, rg_ncand);
    rg_worklist_run();
    for (i = 0; i < rg_vars; i += 1) {
        if (rg_seg_lo[i] != rg_seg_hi[i] &&
            rg_var_spans_clobber(i, rg_callbits)) {
            spans += 1;
        }
    }
    rg_spans_seen += spans;
    conflicts = 0;
    if (rg_verify == 1) {
        conflicts = rg_count_conflicts();
    }
    hash = rg_mix(hash, rg_vars);
    hash = rg_mix(hash, rg_ncand);
    hash = rg_mix(hash, rg_assigned);
    hash = rg_mix(hash, rg_spilled);
    hash = rg_mix(hash, rg_splits);
    hash = rg_mix(hash, rg_evictions);
    hash = rg_mix(hash, spans);
    hash = rg_mix(hash, conflicts);
    for (i = 0; i < rg_ncand; i += 1) {
        int64_t v = rg_tokens[rg_cand_base + i];
        hash = rg_mix(hash, rg_stage[v]);
        hash = rg_mix(hash, rg_kind[v]);
        hash = rg_mix(hash, rg_reg[v]);
    }
    return hash;
}

static int64_t rg_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = rg_read_file(path, &length);
    int64_t capacity = length / 2 + 8;
    int64_t functions;
    int64_t expected_spans;
    int64_t cursor = 3;
    int64_t max_vars = 1;
    int64_t max_segs = 1;
    int64_t max_words;
    int64_t max_point = 1;
    int64_t round = 0;
    int64_t start = 0;
    uint64_t acc = RG_HASH_BASIS;
    int64_t f;

    rg_tokens = rg_alloc(capacity);
    acc = rg_mix(acc, rg_scan_ints(text, length, rg_tokens));
    functions = rg_tokens[1];
    expected_spans = rg_tokens[2];
    rg_offsets = rg_alloc(functions + 1);
    for (f = 0; f < functions; f += 1) {
        int64_t vars = rg_tokens[cursor];
        int64_t nblocks = rg_tokens[cursor + 1];
        int64_t ncand = rg_tokens[cursor + 2];
        int64_t ncall = rg_tokens[cursor + 3];
        int64_t ndiv = rg_tokens[cursor + 4];
        int64_t nshift = rg_tokens[cursor + 5];
        int64_t nseg = rg_tokens[cursor + 6];
        int64_t nrows = rg_tokens[cursor + 7];
        int64_t point = rg_tokens[cursor + 8 + nblocks];
        int64_t p;
        int64_t r;
        rg_offsets[f] = cursor;
        if (vars > max_vars) {
            max_vars = vars;
        }
        if (nseg > max_segs) {
            max_segs = nseg;
        }
        if (point > max_point) {
            max_point = point;
        }
        p = cursor + 8 + nblocks + 1 + ncand + ncall + ndiv + nshift;
        for (r = 0; r < nrows; r += 1) {
            p += 6 + rg_tokens[p + 1] * 2;
        }
        cursor = p;
    }

    max_words = (max_vars + 31) >> 5;
    rg_lowbit = rg_alloc(32);
    rg_pool_reg = rg_alloc(RG_POOL_COUNT);
    rg_pool_idx = rg_alloc(RG_POOL_INDEX_CAPACITY);
    rg_lowbit_init();
    rg_pool_init();
    rg_seg_lo = rg_alloc(max_vars + 1);
    rg_seg_hi = rg_alloc(max_vars + 1);
    rg_seg_start = rg_alloc(max_segs + 1);
    rg_seg_end = rg_alloc(max_segs + 1);
    rg_raw = rg_alloc(max_vars + 1);
    rg_key = rg_alloc(max_vars + 1);
    rg_hint = rg_alloc(max_vars + 1);
    rg_argpref = rg_alloc(max_vars + 1);
    rg_param = rg_alloc(max_vars + 1);
    rg_group = rg_alloc(max_vars + 1);
    rg_present = rg_alloc(max_vars + 1);
    rg_kind = rg_alloc(max_vars + 1);
    rg_reg = rg_alloc(max_vars + 1);
    rg_primary = rg_alloc(max_vars + 1);
    rg_secondary = rg_alloc(max_vars + 1);
    rg_pending = rg_alloc(max_vars + 1);
    rg_evict = rg_alloc(max_vars + 1);
    rg_stage = rg_alloc(max_vars + 1);
    rg_order = rg_alloc(max_vars + 1);
    rg_sortbuf = rg_alloc(max_vars + 1);
    rg_residents = rg_alloc(max_vars + 1);
    rg_heap = rg_alloc(max_vars * 5 + 16);
    rg_occ = rg_alloc(RG_POOL_COUNT * max_words + 1);
    rg_ustride = (max_segs + 1) * RG_ENTRY_WORDS;
    rg_union = rg_alloc(RG_POOL_COUNT * rg_ustride + 1);
    rg_ucount = rg_alloc(RG_POOL_COUNT);
    rg_ucoarse = rg_alloc(RG_POOL_COUNT);
    rg_callbits = rg_alloc((max_point >> 5) + 2);
    rg_divbits = rg_alloc((max_point >> 5) + 2);
    rg_shiftbits = rg_alloc((max_point >> 5) + 2);
    rg_forb = rg_alloc(8);

    while (round < rounds) {
        int64_t step = 0;
        rg_verify = round == 0 ? 1 : 0;
        acc = rg_mix(acc, round);
        while (step < functions) {
            int64_t index = start + step;
            if (index >= functions) {
                index -= functions;
            }
            acc = rg_mix(acc, (int64_t)rg_run_function(rg_offsets[index]));
            step += 1;
        }
        start += 1;
        if (start >= functions) {
            start = 0;
        }
        round += 1;
    }
    free(text);
    return (int64_t)rg_mix(acc, rg_spans_seen - expected_spans * rounds);
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)rg_bench(path, rounds));
    return 0;
}
