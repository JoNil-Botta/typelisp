/* benchmarks/hashmap_grow/baseline.c - clang C baseline for hashmap_grow (#2168).
 *
 * Equivalent to benchmarks/hashmap_grow/bench.tl: insert deterministic i64 keys
 * into an initially small open-addressed map, forcing repeated grows and
 * rehashes, then sample lookups to make the final contents observable. uint64_t
 * gives defined modulo-2^64 wrapping that matches TypeLisp i64 `+`/`*`, so both
 * programs produce the identical exit code on a given host.
 *
 * The entry count is `base_entries + argc` (argc is 1 with no extra arguments,
 * matching TypeLisp `arg-count`), keeping the result deterministic while
 * preventing whole-loop constant folding.
 */
#include <stdint.h>
#include <stdlib.h>

typedef struct {
    uint8_t occupied;
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

static uint64_t bucket_index(uint64_t hash, uint64_t capacity) {
    return hash_normalize(hash) % capacity;
}

static uint64_t next_index(uint64_t index, uint64_t capacity) {
    return (index + 1ULL) % capacity;
}

static uint64_t grow_key(uint64_t i) {
    return i * 131ULL + 17ULL;
}

static uint64_t grow_value(uint64_t key) {
    return key * 33ULL + 7ULL;
}

static Slot *make_slots(uint64_t capacity) {
    return (Slot *)calloc((size_t)capacity, sizeof(Slot));
}

static Map make_map(uint64_t capacity) {
    Map map;
    map.slots = make_slots(capacity);
    map.capacity = capacity;
    map.len = 0;
    return map;
}

static int needs_grow(const Map *map) {
    if (map->capacity == 0) {
        return 1;
    }
    return map->len * 4ULL >= map->capacity * 3ULL;
}

static void insert_into_empty(Slot *slots, uint64_t capacity, uint64_t key, uint64_t value, uint64_t hash) {
    uint64_t cursor = bucket_index(hash, capacity);
    uint64_t walked = 0;
    while (walked < capacity) {
        Slot *slot = &slots[cursor];
        if (!slot->occupied) {
            slot->occupied = 1;
            slot->key = key;
            slot->value = value;
            slot->hash = hash;
            return;
        }
        cursor = next_index(cursor, capacity);
        walked++;
    }
}

static void resize_map(Map *map, uint64_t new_capacity) {
    Slot *dst = make_slots(new_capacity);
    if (!dst) {
        free(map->slots);
        exit(2);
    }
    for (uint64_t i = 0; i < map->capacity; i++) {
        Slot *slot = &map->slots[i];
        if (slot->occupied) {
            insert_into_empty(dst, new_capacity, slot->key, slot->value, slot->hash);
        }
    }
    free(map->slots);
    map->slots = dst;
    map->capacity = new_capacity;
}

static void grow_map(Map *map) {
    uint64_t new_capacity = map->capacity < 4ULL ? 8ULL : map->capacity * 2ULL;
    resize_map(map, new_capacity);
}

static void put(Map *map, uint64_t key, uint64_t value) {
    if (needs_grow(map)) {
        grow_map(map);
    }
    uint64_t hash = hash_key(key);
    uint64_t cursor = bucket_index(hash, map->capacity);
    uint64_t walked = 0;
    while (walked < map->capacity) {
        Slot *slot = &map->slots[cursor];
        if (!slot->occupied) {
            slot->occupied = 1;
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
    grow_map(map);
    put(map, key, value);
}

static uint64_t get_or(const Map *map, uint64_t key, uint64_t fallback) {
    uint64_t hash = hash_key(key);
    uint64_t cursor = bucket_index(hash, map->capacity);
    uint64_t walked = 0;
    while (walked < map->capacity) {
        const Slot *slot = &map->slots[cursor];
        if (!slot->occupied) {
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
    const uint64_t base_entries = 24000ULL;
    uint64_t n = base_entries + (uint64_t)argc;
    Map map = make_map(4ULL);
    if (!map.slots) {
        return 2;
    }
    for (uint64_t i = 0; i < n; i++) {
        uint64_t key = grow_key(i);
        put(&map, key, grow_value(key));
    }
    uint64_t acc = 0;
    for (uint64_t i = 0; i < n; i += 257ULL) {
        uint64_t key = grow_key(i);
        acc += get_or(&map, key, UINT64_MAX);
    }
    acc += map.len + map.capacity;
    free(map.slots);
    return (int)(acc & 0xFFULL);
}
