/* benchmarks/opt_crc32/baseline.c - clang C baseline for opt_crc32.
 *
 * Equivalent to benchmarks/opt_crc32/bench.tl: builds the reflected CRC-32
 * (polynomial 0xEDB88320) table once, then checksums a byte buffer many rounds,
 * perturbing one byte per round, and folds each round's CRC into a wrapping
 * accumulator. All values stay within 32 bits, so uint64_t arithmetic matches
 * TypeLisp's i64 bit ops and the accumulator's printed decimal matches.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CRC_LOW_MASK 4294967295ULL
#define CRC_BYTE_MASK 255ULL
#define CRC_POLY 3988292384ULL

static uint64_t crc_table_entry(uint64_t n) {
    uint64_t crc = n;
    for (int64_t bit = 0; bit < 8; bit += 1) {
        if ((crc & 1ULL) == 1ULL) {
            crc = (crc >> 1) ^ CRC_POLY;
        } else {
            crc = crc >> 1;
        }
    }
    return crc;
}

static void crc_build_table(uint64_t *table) {
    for (int64_t n = 0; n < 256; n += 1) {
        table[n] = crc_table_entry((uint64_t)n);
    }
}

static uint64_t crc_update(const uint64_t *table, const uint8_t *buf, int64_t len) {
    uint64_t crc = CRC_LOW_MASK;
    for (int64_t i = 0; i < len; i += 1) {
        uint64_t byte = (uint64_t)buf[i];
        uint64_t index = (crc ^ byte) & CRC_BYTE_MASK;
        crc = (crc >> 8) ^ table[index];
    }
    return crc ^ CRC_LOW_MASK;
}

static void crc_fill(uint8_t *buf, int64_t len) {
    for (int64_t i = 0; i < len; i += 1) {
        buf[i] = (uint8_t)(((uint64_t)i * 167ULL + 13ULL) & 255ULL);
    }
}

static uint64_t crc_bench(int64_t len, int64_t rounds) {
    uint64_t table[256];
    crc_build_table(table);
    uint8_t *buf = (uint8_t *)malloc((size_t)len);
    if (!buf) {
        abort();
    }
    crc_fill(buf, len);
    uint64_t acc = 0;
    for (int64_t round = 0; round < rounds; round += 1) {
        buf[round % len] = (uint8_t)(((uint64_t)round + 1ULL) & 255ULL);
        acc = (acc + crc_update(table, buf, len)) & CRC_LOW_MASK;
    }
    free(buf);
    return acc;
}

int main(int argc, char **argv) {
    int64_t len = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)crc_bench(len, rounds));
    return 0;
}
