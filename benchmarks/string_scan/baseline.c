/* benchmarks/string_scan/baseline.c - clang C baseline for string_scan (#1098).
 *
 * Equivalent to benchmarks/string_scan/bench.tl: walk a fixed ASCII string
 * `rounds` times, folding every byte into a polynomial rolling hash
 * (acc = acc * 131 + byte) over a wrapping 64-bit accumulator, and return the
 * low byte as the process exit code. uint64_t gives defined modulo-2^64
 * wrapping that matches TypeLisp i64 `+`/`*`. The text is pure ASCII, so each
 * (unsigned char) byte is the same small non-negative code TypeLisp's
 * `string-ref` returns; both programs produce the identical exit code.
 *
 * The round count is `base_rounds + argc` (argc is 1 with no extra arguments,
 * matching TypeLisp `arg-count`), so the trip count is not a compile-time
 * constant. The hash accumulator is carried across rounds, so the per-round
 * scan is not loop-invariant and cannot be folded into a closed form.
 */
#include <stdint.h>
#include <string.h>

static const char *scan_text =
    "the quick brown fox jumps over the lazy dog 0123456789";

static uint64_t scan_once(const char *text, uint64_t n, uint64_t acc) {
    for (uint64_t i = 0; i < n; i++) {
        acc = acc * 131ULL + (uint64_t)(unsigned char)text[i];
    }
    return acc;
}

int main(int argc, char **argv) {
    (void)argv;
    const uint64_t base_rounds = 25000000ULL;
    uint64_t n = (uint64_t)strlen(scan_text);
    uint64_t rounds = base_rounds + (uint64_t)argc;
    uint64_t acc = 1;
    for (uint64_t r = 0; r < rounds; r++) {
        acc = scan_once(scan_text, n, acc);
    }
    return (int)(acc & 0xFFULL);
}
