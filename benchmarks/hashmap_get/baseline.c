/* benchmarks/hashmap_get/baseline.c - clang C baseline for hashmap_get (#2166).
 *
 * Equivalent to benchmarks/hashmap_get/bench.tl: pre-populate a fixed-capacity
 * i64 -> i64 map, then alternate deterministic hit and miss lookups. uint64_t
 * gives modulo-2^64 wrapping compatible with TypeLisp i64 arithmetic for this
 * benchmark's low-byte exit code.
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

static int power_two_capacity(uint64_t capacity) {
    return capacity > 0ULL && (capacity & (capacity - 1ULL)) == 0ULL;
}

static uint64_t normalized_bucket_index(uint64_t hash, uint64_t capacity) {
    if (power_two_capacity(capacity)) {
        return hash & (capacity - 1ULL);
    }
    return hash % capacity;
}

static uint64_t next_index(uint64_t index, uint64_t capacity) {
    uint64_t next = index + 1ULL;
    return next >= capacity ? 0ULL : next;
}

static uint64_t get_key(uint64_t i) {
    return i * 17ULL + 5ULL;
}

static uint64_t get_value(uint64_t key) {
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
    const uint64_t rounds = 1200ULL + (uint64_t)argc;
    const uint64_t size = 2048ULL;
    Map map = make_map(4096ULL);
    if (!map.slots) {
        return 2;
    }

    for (uint64_t i = 0ULL; i < size; i++) {
        uint64_t key = get_key(i);
        insert(&map, key, get_value(key));
    }

    uint64_t acc = 0ULL;
    for (uint64_t round = 0ULL; round < rounds; round++) {
        for (uint64_t hit = 0ULL; hit < size; hit++) {
            uint64_t key = get_key(hit);
            acc += get_or(&map, key, UINT64_MAX);
        }
        for (uint64_t miss = 0ULL; miss < size; miss++) {
            uint64_t key = get_key(miss) + 1ULL;
            acc += get_or(&map, key, 3ULL);
        }
    }

    acc += map.len;
    free(map.slots);
    return (int)(acc & 0xFFULL);
}
