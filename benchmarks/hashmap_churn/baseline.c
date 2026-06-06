/* benchmarks/hashmap_churn/baseline.c - clang C baseline for hashmap_churn (#2167).
 *
 * Equivalent to benchmarks/hashmap_churn/bench.tl: insert deterministic i64
 * keys, remove every third key from each batch, and sample lookups so the final
 * map contents stay observable. uint64_t gives modulo-2^64 wrapping compatible
 * with TypeLisp i64 arithmetic for this benchmark's low-byte exit code.
 */
#include <stdint.h>
#include <stdlib.h>

enum {
    SLOT_EMPTY = 0,
    SLOT_OCCUPIED = 1,
    SLOT_TOMBSTONE = 2
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
    uint64_t deleted;
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

static uint64_t churn_key(uint64_t round, uint64_t i) {
    return round * 1000003ULL + i * 131ULL + 17ULL;
}

static uint64_t churn_value(uint64_t key) {
    return key * 33ULL + 7ULL;
}

static Slot *make_slots(uint64_t capacity) {
    return (Slot *)calloc((size_t)capacity, sizeof(Slot));
}

static Map make_map(uint64_t capacity) {
    Map map;
    map.slots = make_slots(capacity);
    map.capacity = capacity;
    map.len = 0ULL;
    map.deleted = 0ULL;
    return map;
}

static void insert_into_empty(Slot *slots, uint64_t capacity, uint64_t key, uint64_t value, uint64_t hash) {
    uint64_t cursor = normalized_bucket_index(hash, capacity);
    uint64_t walked = 0ULL;
    while (walked < capacity) {
        Slot *slot = &slots[cursor];
        if (slot->state == SLOT_EMPTY) {
            slot->state = SLOT_OCCUPIED;
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
    for (uint64_t i = 0ULL; i < map->capacity; i++) {
        Slot *slot = &map->slots[i];
        if (slot->state == SLOT_OCCUPIED) {
            insert_into_empty(dst, new_capacity, slot->key, slot->value, slot->hash);
        }
    }
    free(map->slots);
    map->slots = dst;
    map->capacity = new_capacity;
    map->deleted = 0ULL;
}

static uint64_t grow_capacity(uint64_t capacity) {
    return capacity < 4ULL ? 8ULL : capacity * 2ULL;
}

static void grow_map(Map *map) {
    resize_map(map, grow_capacity(map->capacity));
}

static int needs_grow(const Map *map) {
    if (map->capacity == 0ULL) {
        return 1;
    }
    return (map->len + map->deleted) * 4ULL >= map->capacity * 3ULL;
}

static int insert(Map *map, uint64_t key, uint64_t value) {
    if (map->capacity == 0ULL) {
        return 0;
    }
    uint64_t hash = hash_key(key);
    uint64_t cursor = normalized_bucket_index(hash, map->capacity);
    uint64_t walked = 0ULL;
    uint64_t first_tombstone = UINT64_MAX;
    while (walked < map->capacity) {
        Slot *slot = &map->slots[cursor];
        if (slot->state == SLOT_EMPTY) {
            uint64_t index = first_tombstone == UINT64_MAX ? cursor : first_tombstone;
            Slot *dst = &map->slots[index];
            dst->state = SLOT_OCCUPIED;
            dst->key = key;
            dst->value = value;
            dst->hash = hash;
            map->len++;
            if (first_tombstone != UINT64_MAX) {
                map->deleted--;
            }
            return 1;
        }
        if (slot->state == SLOT_TOMBSTONE) {
            if (first_tombstone == UINT64_MAX) {
                first_tombstone = cursor;
            }
        } else if (slot->hash == hash && slot->key == key) {
            slot->value = value;
            return 1;
        }
        cursor = next_index(cursor, map->capacity);
        walked++;
    }
    if (first_tombstone != UINT64_MAX) {
        Slot *dst = &map->slots[first_tombstone];
        dst->state = SLOT_OCCUPIED;
        dst->key = key;
        dst->value = value;
        dst->hash = hash;
        map->len++;
        map->deleted--;
        return 1;
    }
    return 0;
}

static void put(Map *map, uint64_t key, uint64_t value) {
    if (needs_grow(map)) {
        grow_map(map);
    }
    if (!insert(map, key, value)) {
        grow_map(map);
        (void)insert(map, key, value);
    }
}

static void remove_key(Map *map, uint64_t key) {
    if (map->capacity == 0ULL) {
        return;
    }
    uint64_t hash = hash_key(key);
    uint64_t cursor = normalized_bucket_index(hash, map->capacity);
    uint64_t walked = 0ULL;
    while (walked < map->capacity) {
        Slot *slot = &map->slots[cursor];
        if (slot->state == SLOT_EMPTY) {
            return;
        }
        if (slot->state == SLOT_OCCUPIED && slot->hash == hash && slot->key == key) {
            slot->state = SLOT_TOMBSTONE;
            map->len--;
            map->deleted++;
            return;
        }
        cursor = next_index(cursor, map->capacity);
        walked++;
    }
}

static uint64_t get_or(const Map *map, uint64_t key, uint64_t fallback) {
    if (map->capacity == 0ULL) {
        return fallback;
    }
    uint64_t hash = hash_key(key);
    uint64_t cursor = normalized_bucket_index(hash, map->capacity);
    uint64_t walked = 0ULL;
    while (walked < map->capacity) {
        const Slot *slot = &map->slots[cursor];
        if (slot->state == SLOT_EMPTY) {
            return fallback;
        }
        if (slot->state == SLOT_OCCUPIED && slot->hash == hash && slot->key == key) {
            return slot->value;
        }
        cursor = next_index(cursor, map->capacity);
        walked++;
    }
    return fallback;
}

int main(int argc, char **argv) {
    (void)argv;
    const uint64_t rounds = 320ULL + (uint64_t)argc;
    const uint64_t batch_size = 96ULL;
    Map map = make_map(8ULL);
    if (!map.slots) {
        return 2;
    }
    uint64_t acc = 0ULL;
    for (uint64_t round = 0ULL; round < rounds; round++) {
        for (uint64_t i = 0ULL; i < batch_size; i++) {
            uint64_t key = churn_key(round, i);
            put(&map, key, churn_value(key));
        }
        for (uint64_t i = 0ULL; i < batch_size; i++) {
            if (i % 11ULL == 0ULL) {
                uint64_t key = churn_key(round, i);
                acc += get_or(&map, key, UINT64_MAX);
            }
        }
        for (uint64_t i = 0ULL; i < batch_size; i++) {
            if (i % 3ULL == 0ULL) {
                remove_key(&map, churn_key(round, i));
            }
        }
    }
    acc += map.len;
    free(map.slots);
    return (int)(acc & 0xFFULL);
}
