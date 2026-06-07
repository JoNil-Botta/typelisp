/* benchmarks/hashmap_insert/baseline.c - clang C baseline for hashmap_insert (#2165).
 *
 * Equivalent to benchmarks/hashmap_insert/bench.tl: repeatedly build a fresh
 * power-of-two i64 -> i64 map, insert deterministic keys, and sample a lookup
 * so the populated map contents stay observable. uint64_t gives modulo-2^64
 * wrapping compatible with TypeLisp i64 arithmetic for this benchmark's
 * low-byte exit code.
 */
#include <stdint.h>
#include <stdlib.h>

enum {
    SLOT_EMPTY = 0,
    SLOT_OCCUPIED = 1
};

typedef struct {
    uint8_t state;
    uint64_t key;
    uint64_t value;
    uint64_t hash;
} Slot;

typedef struct {
    Slot *slots;
    uint64_t capacity;
    uint64_t len;
} Map;

static uint64_t hash_normalize(uint64_t value) {
    return value % 2147483647ULL;
}

static uint64_t hash_key(uint64_t key) {
    return hash_normalize(key);
}

static uint64_t normalized_bucket_index(uint64_t hash, uint64_t capacity) {
    return hash & (capacity - 1ULL);
}

static uint64_t next_index(uint64_t index, uint64_t capacity) {
    uint64_t next = index + 1ULL;
    return next >= capacity ? 0ULL : next;
}

static uint64_t insert_key(uint64_t round, uint64_t i) {
    return round * 1000003ULL + i * 17ULL + 5ULL;
}

static uint64_t insert_value(uint64_t key) {
    return key * 33ULL + 7ULL;
}

static Map make_map(uint64_t capacity) {
    Map map;
    map.slots = (Slot *)calloc((size_t)capacity, sizeof(Slot));
    map.capacity = capacity;
    map.len = 0ULL;
    return map;
}

static void insert(Map *map, uint64_t key, uint64_t value) {
    uint64_t hash = hash_key(key);
    uint64_t cursor = normalized_bucket_index(hash, map->capacity);
    uint64_t walked = 0ULL;
    while (walked < map->capacity) {
        Slot *slot = &map->slots[cursor];
        if (slot->state == SLOT_EMPTY) {
            slot->state = SLOT_OCCUPIED;
            slot->key = key;
            slot->value = value;
            slot->hash = hash;
            map->len++;
            return;
        }
        if (slot->hash == hash && slot->key == key) {
            slot->value = value;
            return;
        }
        cursor = next_index(cursor, map->capacity);
        walked++;
    }
}

static uint64_t get_or(const Map *map, uint64_t key, uint64_t fallback) {
    uint64_t hash = hash_key(key);
    uint64_t cursor = normalized_bucket_index(hash, map->capacity);
    uint64_t walked = 0ULL;
    while (walked < map->capacity) {
        const Slot *slot = &map->slots[cursor];
        if (slot->state == SLOT_EMPTY) {
            return fallback;
        }
        if (slot->hash == hash && slot->key == key) {
            return slot->value;
        }
        cursor = next_index(cursor, map->capacity);
        walked++;
    }
    return fallback;
}

int main(int argc, char **argv) {
    (void)argv;
    const uint64_t rounds = 640ULL + (uint64_t)argc;
    const uint64_t size = 1024ULL;
    uint64_t acc = 0ULL;

    for (uint64_t round = 0ULL; round < rounds; round++) {
        Map map = make_map(2048ULL);
        if (!map.slots) {
            return 2;
        }
        for (uint64_t i = 0ULL; i < size; i++) {
            uint64_t key = insert_key(round, i);
            insert(&map, key, insert_value(key));
        }
        uint64_t sample = round % size;
        uint64_t sample_key = insert_key(round, sample);
        acc += map.len + get_or(&map, sample_key, UINT64_MAX);
        free(map.slots);
    }

    return (int)(acc & 0xFFULL);
}
