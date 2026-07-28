/* benchmarks/liveness_scan/baseline.c - clang C baseline for liveness_scan.
 *
 * Equivalent to benchmarks/liveness_scan/bench.tl: the backward liveness
 * fixpoint of src/compiler_liveness.tl, run over REAL dataflow input. The
 * corpus in benchmarks/liveness_scan/data/cfgs.txt holds the per-function CFGs
 * and use/def sets the compiler's own liveness pass consumes when it lowers
 * src/compiler_liveness.tl (2087 functions, 12172 blocks, that module plus
 * every module it imports), captured from `typelisp compile --dump-ir` by
 * benchmarks/liveness_scan/tools/export_cfgs.py. Blocks are in dump order,
 * which is the lowering's deterministic reverse postorder.
 *
 * Mirrored: `compiler-live-fixpoint` and `compiler-live-fixpoint-ep` (seed all
 * blocks pending, `compiler-live-worklist-pick!` scanning down for the last
 * pending block, recompute, and on a change store and re-enqueue predecessors
 * via `compiler-live-worklist-enqueue-predecessors!`),
 * `compiler-live-recompute-block-graph` and `-ep` (live-out is the union of the
 * successors' live-in plus, for the edge-precise entry, the block's `phi-out`
 * set; live-in is `uses | (live-out - defs)`),
 * `compiler-live-block-liveness-eq?`, `compiler-live-predecessors-build`,
 * the THIRTY-TWO-bits-per-i64-word packing of `compiler-live-set-word-bits` /
 * `-word-shift` / `-word-mask`, and `compiler-live-set-trim-length` +
 * `compiler-live-set-count` for the population count.
 *
 * The ordinary entry takes block uses that include phi operands
 * (`compiler-live-build-block`); the edge-precise entry takes uses that exclude
 * them (`compiler-live-build-block-nophi`) and unions `phi-out` into live-out,
 * which is what `compiler-live-phi-out-add-inputs!` accumulates.
 *
 * A round runs both entries over every function from a cleared state and folds
 * every block's live-in population count. TypeLisp `+`/`-`/`*` wrap modulo
 * 2^64, so the accumulator is uint64_t here and the printed decimal matches
 * TypeLisp's print of an i64.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* `compiler-live-set-word-shift` / `-word-mask`: the compiler's
 * `compiler-live-set-word-bits` is THIRTY-TWO, so an i64 word carries 32 set
 * members, not 64. */
#define LN_WORD_SHIFT 5
#define LN_WORD_MASK 31

static int64_t ln_word_index(int64_t value) { return value >> LN_WORD_SHIFT; }

static int64_t ln_bit_mask(int64_t value) {
    return (int64_t)1 << (value & LN_WORD_MASK);
}

static int64_t ln_words_for(int64_t vars) {
    return (vars + LN_WORD_MASK) >> LN_WORD_SHIFT;
}

static void ln_set_bit(int64_t *words, int64_t base, int64_t value) {
    int64_t slot = base + ln_word_index(value);
    words[slot] = words[slot] | ln_bit_mask(value);
}

/* ---- corpus parsing ---- */
/* The corpus is a whitespace-separated stream of non-negative decimals and
 * nothing else, so one scanner serves both implementations. */
static int ln_digit(int64_t c) { return c >= 48 && c <= 57; }

static int64_t ln_count_tokens(const unsigned char *buf, int64_t n) {
    int64_t count = 0;
    int inside = 0;
    for (int64_t i = 0; i < n; i += 1) {
        int64_t c = (int64_t)buf[i];
        if (ln_digit(c)) {
            if (!inside) {
                count += 1;
                inside = 1;
            }
        } else {
            inside = 0;
        }
    }
    return count;
}

static void ln_fill_tokens(const unsigned char *buf, int64_t n,
                           int64_t *tokens) {
    int64_t count = 0;
    int64_t value = 0;
    int inside = 0;
    for (int64_t i = 0; i < n; i += 1) {
        int64_t c = (int64_t)buf[i];
        if (ln_digit(c)) {
            value = value * 10 + (c - 48);
            inside = 1;
        } else if (inside) {
            tokens[count] = value;
            count += 1;
            value = 0;
            inside = 0;
        }
    }
    if (inside) {
        tokens[count] = value;
        count += 1;
    }
}

/* ---- the dataflow ---- */
/* `compiler-live-successor-live-out-graph-loop` then the phi-out union of
 * `compiler-live-recompute-block-graph-ep`, into a scratch word slice. */
static void ln_live_out_into(int64_t *scratch, int64_t words, int64_t g,
                             const int64_t *succ_start,
                             const int64_t *succ_items, const int64_t *live_in,
                             int64_t word_base, int64_t block_base,
                             const int64_t *phi_out, int with_phi_out) {
    int64_t stop = succ_start[g + 1];
    int64_t slot = succ_start[g];
    for (int64_t k = 0; k < words; k += 1) {
        scratch[k] = 0;
    }
    while (slot < stop) {
        int64_t succ = succ_items[slot];
        int64_t succ_base = word_base + (succ - block_base) * words;
        for (int64_t i = 0; i < words; i += 1) {
            scratch[i] = scratch[i] | live_in[succ_base + i];
        }
        slot += 1;
    }
    if (with_phi_out) {
        int64_t self_base = word_base + (g - block_base) * words;
        for (int64_t i = 0; i < words; i += 1) {
            scratch[i] = scratch[i] | phi_out[self_base + i];
        }
    }
}

/* `compiler-live-recompute-block-graph`: live-in is `uses | (live-out - defs)`.
 * The result is compared against the stored sets (`compiler-live-block-
 * liveness-eq?`) and only written back when it differs. */
static int ln_recompute(int64_t g, int64_t words, int64_t word_base,
                        int64_t block_base, const int64_t *succ_start,
                        const int64_t *succ_items, const int64_t *uses,
                        const int64_t *defs, const int64_t *phi_out,
                        int64_t *live_in, int64_t *live_out,
                        int64_t *scratch_out, int64_t *scratch_in,
                        int with_phi_out) {
    int64_t self_base = word_base + (g - block_base) * words;
    int64_t i = 0;
    int changed = 0;

    ln_live_out_into(scratch_out, words, g, succ_start, succ_items, live_in,
                     word_base, block_base, phi_out, with_phi_out);
    for (i = 0; i < words; i += 1) {
        scratch_in[i] =
            uses[self_base + i] | (scratch_out[i] & ~defs[self_base + i]);
    }
    for (i = 0; i < words && !changed; i += 1) {
        if (scratch_in[i] != live_in[self_base + i] ||
            scratch_out[i] != live_out[self_base + i]) {
            changed = 1;
        }
    }
    if (changed) {
        for (int64_t k = 0; k < words; k += 1) {
            live_in[self_base + k] = scratch_in[k];
            live_out[self_base + k] = scratch_out[k];
        }
    }
    return changed;
}

/* `compiler-live-fixpoint` / `compiler-live-fixpoint-ep` over one function. */
static void ln_fixpoint(int64_t block_base, int64_t blocks, int64_t words,
                        int64_t word_base, const int64_t *succ_start,
                        const int64_t *succ_items, const int64_t *pred_start,
                        const int64_t *pred_items, const int64_t *uses,
                        const int64_t *defs, const int64_t *phi_out,
                        int64_t *live_in, int64_t *live_out, int64_t *pending,
                        int64_t *scratch_out, int64_t *scratch_in,
                        int with_phi_out) {
    int done = 0;

    /* `compiler-live-worklist-seed!` plus the cleared entry state every
     * `compiler-live-build-block` starts from. */
    for (int64_t b = 0; b < blocks; b += 1) {
        int64_t self_base = word_base + b * words;
        pending[block_base + b] = 1;
        for (int64_t k = 0; k < words; k += 1) {
            live_in[self_base + k] = 0;
            live_out[self_base + k] = 0;
        }
    }

    while (!done) {
        int64_t index = -1;
        int64_t i = blocks - 1;
        /* `compiler-live-worklist-pick!`: scan down for the last pending block,
         * which is the backward order the lowering's layout wants. */
        while (i >= 0 && index < 0) {
            if (pending[block_base + i] == 1) {
                pending[block_base + i] = 0;
                index = i;
            }
            i -= 1;
        }
        if (index < 0) {
            done = 1;
        } else if (ln_recompute(block_base + index, words, word_base,
                                block_base, succ_start, succ_items, uses, defs,
                                phi_out, live_in, live_out, scratch_out,
                                scratch_in, with_phi_out)) {
            /* `compiler-live-worklist-enqueue-predecessors!` */
            int64_t g = block_base + index;
            int64_t slot = pred_start[g];
            int64_t stop = pred_start[g + 1];
            while (slot < stop) {
                pending[pred_items[slot]] = 1;
                slot += 1;
            }
        }
    }
}

/* `compiler-live-set-trim-length` then `compiler-live-set-count` over the
 * trimmed prefix. The compiler's `compiler-live-set-word-count-bits` tests all
 * thirty-two bit positions of every word; this counts by clearing the lowest
 * set bit instead, so the checksum costs work proportional to the live-in sets
 * rather than to the universe. Same value, and it keeps this row a measurement
 * of the fixpoint: with the compiler's per-bit spelling the fold alone is 78%
 * of the TypeLisp row. */
static int64_t ln_set_count(const int64_t *words_array, int64_t base,
                            int64_t words) {
    int64_t n = words;
    int64_t count = 0;

    while (n > 0 && words_array[base + n - 1] == 0) {
        n -= 1;
    }
    for (int64_t i = 0; i < n; i += 1) {
        int64_t bits = words_array[base + i];
        while (bits != 0) {
            bits = bits & (bits - 1);
            count += 1;
        }
    }
    return count;
}

static uint64_t ln_fold_live_in(const int64_t *live_in, int64_t word_base,
                                int64_t blocks, int64_t words,
                                uint64_t seed_acc) {
    uint64_t acc = seed_acc;
    for (int64_t b = 0; b < blocks; b += 1) {
        acc = acc * 1000003u +
              (uint64_t)ln_set_count(live_in, word_base + b * words, words) *
                  2654435761u;
    }
    return acc;
}

static void *ln_alloc(size_t bytes) {
    void *items = calloc(bytes, 1);
    if (!items) {
        abort();
    }
    return items;
}

static uint64_t ln_bench(const char *path, int64_t rounds) {
    FILE *handle = fopen(path, "rb");
    unsigned char *text = 0;
    long size = 0;
    int64_t n = 0;
    int64_t token_count = 0;
    int64_t *tokens = 0;
    int64_t functions = 0;
    int64_t total_blocks = 0;
    int64_t total_words = 0;
    int64_t total_succ = 0;
    int64_t max_words = 1;
    int64_t p = 0;
    int64_t block_base = 0;
    int64_t word_base = 0;
    int64_t succ_cursor = 0;
    uint64_t acc = 0;

    int64_t *fn_block_base;
    int64_t *fn_word_base;
    int64_t *fn_blocks;
    int64_t *fn_words;
    int64_t *succ_start;
    int64_t *succ_items;
    int64_t *pred_start;
    int64_t *pred_items;
    int64_t *pred_cursor;
    int64_t *uses;
    int64_t *uses_nophi;
    int64_t *defs;
    int64_t *phi_out;
    int64_t *live_in;
    int64_t *live_out;
    int64_t *pending;
    int64_t *scratch_out;
    int64_t *scratch_in;

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
    text = (unsigned char *)ln_alloc((size_t)size + 1);
    if (fread(text, 1, (size_t)size, handle) != (size_t)size) {
        abort();
    }
    fclose(handle);
    n = (int64_t)size;

    token_count = ln_count_tokens(text, n);
    tokens = (int64_t *)ln_alloc(((size_t)token_count + 1) * sizeof(int64_t));
    ln_fill_tokens(text, n, tokens);

    /* Sizing pass over the token stream. */
    p = 1;
    functions = tokens[p];
    p += 1;
    for (int64_t f = 0; f < functions; f += 1) {
        int64_t vars = tokens[p];
        int64_t blocks = tokens[p + 1];
        int64_t words = ln_words_for(vars);
        p += 2;
        total_blocks += blocks;
        total_words += blocks * words;
        if (words > max_words) {
            max_words = words;
        }
        for (int64_t b = 0; b < blocks; b += 1) {
            for (int64_t k = 0; k < 5; k += 1) {
                int64_t c = tokens[p];
                if (k == 0) {
                    total_succ += c;
                }
                p += 1 + c;
            }
        }
    }

    fn_block_base = (int64_t *)ln_alloc(((size_t)functions + 1) * sizeof(int64_t));
    fn_word_base = (int64_t *)ln_alloc(((size_t)functions + 1) * sizeof(int64_t));
    fn_blocks = (int64_t *)ln_alloc(((size_t)functions + 1) * sizeof(int64_t));
    fn_words = (int64_t *)ln_alloc(((size_t)functions + 1) * sizeof(int64_t));
    succ_start = (int64_t *)ln_alloc(((size_t)total_blocks + 1) * sizeof(int64_t));
    succ_items = (int64_t *)ln_alloc(((size_t)total_succ + 1) * sizeof(int64_t));
    pred_start = (int64_t *)ln_alloc(((size_t)total_blocks + 2) * sizeof(int64_t));
    pred_items = (int64_t *)ln_alloc(((size_t)total_succ + 1) * sizeof(int64_t));
    pred_cursor = (int64_t *)ln_alloc(((size_t)total_blocks + 1) * sizeof(int64_t));
    uses = (int64_t *)ln_alloc(((size_t)total_words + 1) * sizeof(int64_t));
    uses_nophi = (int64_t *)ln_alloc(((size_t)total_words + 1) * sizeof(int64_t));
    defs = (int64_t *)ln_alloc(((size_t)total_words + 1) * sizeof(int64_t));
    phi_out = (int64_t *)ln_alloc(((size_t)total_words + 1) * sizeof(int64_t));
    live_in = (int64_t *)ln_alloc(((size_t)total_words + 1) * sizeof(int64_t));
    live_out = (int64_t *)ln_alloc(((size_t)total_words + 1) * sizeof(int64_t));
    pending = (int64_t *)ln_alloc(((size_t)total_blocks + 1) * sizeof(int64_t));
    scratch_out = (int64_t *)ln_alloc(((size_t)max_words + 1) * sizeof(int64_t));
    scratch_in = (int64_t *)ln_alloc(((size_t)max_words + 1) * sizeof(int64_t));

    /* Fill pass over the token stream. */
    p = 2;
    for (int64_t f = 0; f < functions; f += 1) {
        int64_t vars = tokens[p];
        int64_t blocks = tokens[p + 1];
        int64_t words = ln_words_for(vars);
        p += 2;
        fn_block_base[f] = block_base;
        fn_word_base[f] = word_base;
        fn_blocks[f] = blocks;
        fn_words[f] = words;
        for (int64_t b = 0; b < blocks; b += 1) {
            int64_t g = block_base + b;
            int64_t self_base = word_base + b * words;
            int64_t count = 0;
            succ_start[g] = succ_cursor;
            count = tokens[p];
            p += 1;
            for (int64_t j = 0; j < count; j += 1) {
                succ_items[succ_cursor] = block_base + tokens[p];
                succ_cursor += 1;
                p += 1;
            }
            count = tokens[p];
            p += 1;
            for (int64_t j = 0; j < count; j += 1) {
                ln_set_bit(uses, self_base, tokens[p]);
                p += 1;
            }
            count = tokens[p];
            p += 1;
            for (int64_t j = 0; j < count; j += 1) {
                ln_set_bit(uses_nophi, self_base, tokens[p]);
                p += 1;
            }
            count = tokens[p];
            p += 1;
            for (int64_t j = 0; j < count; j += 1) {
                ln_set_bit(defs, self_base, tokens[p]);
                p += 1;
            }
            count = tokens[p];
            p += 1;
            for (int64_t j = 0; j < count; j += 1) {
                ln_set_bit(phi_out, self_base, tokens[p]);
                p += 1;
            }
        }
        block_base += blocks;
        word_base += blocks * words;
    }
    succ_start[total_blocks] = succ_cursor;

    /* `compiler-live-predecessors-build`: count, then fill. */
    for (int64_t i = 0; i < succ_cursor; i += 1) {
        int64_t target = succ_items[i];
        pred_cursor[target] = pred_cursor[target] + 1;
    }
    {
        int64_t running = 0;
        for (int64_t i = 0; i < total_blocks; i += 1) {
            pred_start[i] = running;
            running += pred_cursor[i];
            pred_cursor[i] = pred_start[i];
        }
        pred_start[total_blocks] = running;
    }
    for (int64_t i = 0; i < total_blocks; i += 1) {
        int64_t slot = succ_start[i];
        int64_t stop = succ_start[i + 1];
        while (slot < stop) {
            int64_t target = succ_items[slot];
            int64_t at = pred_cursor[target];
            pred_items[at] = i;
            pred_cursor[target] = at + 1;
            slot += 1;
        }
    }

    for (int64_t round = 0; round < rounds; round += 1) {
        for (int64_t f = 0; f < functions; f += 1) {
            int64_t base = fn_block_base[f];
            int64_t blocks = fn_blocks[f];
            int64_t words = fn_words[f];
            int64_t wbase = fn_word_base[f];
            /* `compiler-live-analyze-function`: the ordinary pass. */
            ln_fixpoint(base, blocks, words, wbase, succ_start, succ_items,
                        pred_start, pred_items, uses, defs, phi_out, live_in,
                        live_out, pending, scratch_out, scratch_in, 0);
            acc = ln_fold_live_in(live_in, wbase, blocks, words, acc);
            /* `compiler-live-analyze-blocks-edge-precise`. */
            ln_fixpoint(base, blocks, words, wbase, succ_start, succ_items,
                        pred_start, pred_items, uses_nophi, defs, phi_out,
                        live_in, live_out, pending, scratch_out, scratch_in, 1);
            acc = ln_fold_live_in(live_in, wbase, blocks, words, acc);
        }
    }

    free(text);
    free(tokens);
    free(fn_block_base);
    free(fn_word_base);
    free(fn_blocks);
    free(fn_words);
    free(succ_start);
    free(succ_items);
    free(pred_start);
    free(pred_items);
    free(pred_cursor);
    free(uses);
    free(uses_nophi);
    free(defs);
    free(phi_out);
    free(live_in);
    free(live_out);
    free(pending);
    free(scratch_out);
    free(scratch_in);
    return acc * 1000003u + (uint64_t)total_blocks;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)ln_bench(path, rounds));
    return 0;
}
