/* benchmarks/radix_sort/baseline.c - clang C baseline for radix_sort.
 *
 * Equivalent to benchmarks/radix_sort/bench.tl: each round fills `count`
 * `(uint64_t key, int64_t val)` records from a deterministic SplitMix64 stream,
 * sorts them via 8-pass 8-bit LSD radix sort with 256-bucket prefix sums and
 * double-buffered ping-pong scatter, asserts non-decreasing key order, and
 * folds all sorted records into a wrapping 64-bit FNV-1a checksum.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define RS_HASH_BASIS 0xcbf29ce484222325ULL
#define RS_HASH_PRIME 1099511628211ULL

typedef struct {
    uint64_t key;
    int64_t val;
} Record;

static uint64_t rs_mix(uint64_t h, uint64_t v) {
    return (h ^ v) * RS_HASH_PRIME;
}

static uint64_t rs_splitmix(uint64_t x) {
    uint64_t z = x + 0x9e3779b97f4a7c15ULL;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static uint64_t rs_fill(Record *dst, int64_t n, uint64_t seed, int64_t round) {
    uint64_t state = seed;
    int64_t r_tag = (int64_t)((uint64_t)round * 1315423911ULL);
    for (int64_t i = 0; i < n; i++) {
        state += 0x9e3779b97f4a7c15ULL;
        dst[i].key = rs_splitmix(state);
        dst[i].val = i ^ r_tag;
    }
    return state;
}

static void rs_pass(const Record *src, Record *dst, int64_t counts[256],
                    int64_t n, uint64_t shift) {
    for (int64_t b = 0; b < 256; b++) {
        counts[b] = 0;
    }
    for (int64_t i = 0; i < n; i++) {
        int64_t bucket = (int64_t)((src[i].key >> shift) & 255ULL);
        counts[bucket] += 1;
    }
    int64_t sum = 0;
    for (int64_t b = 0; b < 256; b++) {
        int64_t c = counts[b];
        counts[b] = sum;
        sum += c;
    }
    for (int64_t i = 0; i < n; i++) {
        Record rec = src[i];
        int64_t bucket = (int64_t)((rec.key >> shift) & 255ULL);
        int64_t pos = counts[bucket];
        counts[bucket] = pos + 1;
        dst[pos] = rec;
    }
}

static uint64_t rs_verify_and_hash(const Record *src, int64_t n, uint64_t acc) {
    uint64_t h = acc;
    uint64_t prev = 0;
    for (int64_t i = 0; i < n; i++) {
        Record rec = src[i];
        if (i > 0 && rec.key < prev) {
            fprintf(stderr, "radix sort order violation\n");
            abort();
        }
        prev = rec.key;
        h = rs_mix(h, rec.key);
        h = rs_mix(h, (uint64_t)rec.val);
    }
    return h;
}

static uint64_t rs_bench(int64_t n, int64_t rounds) {
    Record *a = (Record *)calloc((size_t)n, sizeof(Record));
    Record *b = (Record *)calloc((size_t)n, sizeof(Record));
    if (!a || !b) abort();
    int64_t counts[256];
    uint64_t state = 0x123456789abcdef0ULL;
    uint64_t acc = RS_HASH_BASIS;

    for (int64_t round = 0; round < rounds; round++) {
        state = rs_fill(a, n, state, round);
        for (uint64_t shift = 0; shift < 64; shift += 16) {
            rs_pass(a, b, counts, n, shift);
            rs_pass(b, a, counts, n, shift + 8);
        }
        acc = rs_verify_and_hash(a, n, acc);
    }

    free(a);
    free(b);
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%" PRIu64 "\n", rs_bench(n, rounds));
    return 0;
}
