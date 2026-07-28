/* benchmarks/intern_table/baseline.c - clang C baseline for intern_table.
 *
 * Equivalent to benchmarks/intern_table/bench.tl: the hash, open-address probe,
 * slice storage, and load-factor growth of src/compiler_intern.tl, the interner
 * the `intern.slice_misses` / `intern.slice_hits` compile-profile rows
 * instrument, run over the REAL identifier stream in
 * benchmarks/intern_table/data/idents.txt (every `Token.Sym` lexeme src/lex.tl
 * produces for src/lex.tl, src/compiler_liveness.tl, src/compiler_symbols.tl
 * and src/compiler_lower.tl, one per line, in encounter order, exported by
 * benchmarks/intern_table/tools/export_idents.py).
 *
 * Mirrored: `intern-hash-words` (seed 5381 + len, 64-bit little-endian words
 * folded with 0x9E3779B97F4A7C15, a `tail = tail * 256 + byte` remainder, and
 * the `h ^= h >> 29` finalizer), `intern-bucket` (mask, power-of-two capacity),
 * `intern-slice`'s probe loop (empty slot is a miss, equal stored hash plus an
 * equal byte compare is a hit, otherwise a linear step, bounded by capacity),
 * `intern-string-slice-eq?`, the `id + 1` compact id lane of
 * `intern-id-slot-encode`, `intern-persistent-substring`'s copy-on-miss name
 * pool, `intern-map-insert-existing-from`, the rehash-all of
 * `intern-map-rebuild-prefix` / `intern-map-insert-existing!`, the
 * `(count + 1) * 4 >= capacity * 3` doubling rule of
 * `intern-structural-table-intern` / `intern-structural-table-grow-map!`, and
 * `intern-reset!`.
 *
 * The compiler loads each hash word with one raw 64-bit read; both
 * implementations here spell that load as an explicit little-endian byte
 * composition instead, so neither side gets a pointer path the other lacks. The
 * hash values are identical on a little-endian host.
 *
 * A round is one compile: pass A interns the whole stream into a fresh table,
 * pass B re-interns it against the populated table (the hit-dominated re-read).
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64, so every accumulator here is uint64_t
 * and the printed decimal matches TypeLisp's print of an i64.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

/* `intern-hash-words`'s multiplier, 0x9E3779B97F4A7C15. */
#define IT_HASH_MULTIPLIER 11400714819323198485ULL

/* Initial map capacity. A power of two, so `intern-bucket` stays a mask. */
#define IT_INITIAL_CAPACITY 1024

/* `intern-hash-words`, with the compiler's raw 64-bit word load spelled as an
 * explicit little-endian composition of eight bytes. */
static uint64_t it_load_word(const unsigned char *src, int64_t at) {
    uint64_t word = 0;
    for (int64_t b = 7; b >= 0; b -= 1) {
        word = (word << 8) | (uint64_t)src[at + b];
    }
    return word;
}

static int64_t it_hash_words(const unsigned char *src, int64_t start,
                             int64_t len) {
    uint64_t h = (uint64_t)(5381 + len);
    int64_t i = 0;
    int64_t words = len - 7;
    uint64_t tail = 0;

    while (i < words) {
        h = (h ^ it_load_word(src, start + i)) * IT_HASH_MULTIPLIER;
        i += 8;
    }
    while (i < len) {
        tail = tail * 256u + (uint64_t)src[start + i];
        i += 1;
    }
    h = (h ^ tail) * IT_HASH_MULTIPLIER;
    return (int64_t)(h ^ (h >> 29));
}

/* Mask `hash` into `[0, capacity)`; capacity is a power of two. */
static int64_t it_bucket(int64_t hash, int64_t capacity) {
    return hash & (capacity - 1);
}

/* `intern-string-slice-eq?`: compare a pool name against a source slice. */
static int it_slice_eq(const unsigned char *names, int64_t name_start,
                       int64_t name_length, const unsigned char *text,
                       int64_t start, int64_t len) {
    if (name_length == len) {
        int64_t i = 0;
        int ok = 1;
        while (i < len && ok) {
            if (names[name_start + i] == text[start + i]) {
                /* keep scanning */
            } else {
                ok = 0;
            }
            i += 1;
        }
        return ok;
    }
    return 0;
}

/* The whole interner state, so the probe helpers take one handle the way the
 * compiler's helpers read one set of module globals. */
typedef struct {
    int64_t *map_ids;
    int64_t *map_hashes;
    unsigned char *names;
    int64_t *name_off;
    int64_t *name_len;
    int64_t capacity;
    int64_t count;
    int64_t name_cursor;
} InternTable;

/* `intern-map-insert-existing-from`: probe forward from `cursor` for the first
 * empty id lane and claim it. The id lane stores `id + 1`, so zero is empty. */
static void it_map_insert_from(InternTable *table, int64_t id, int64_t hash,
                               int64_t cursor, int64_t capacity) {
    int64_t slot = cursor;
    int64_t probes = 0;
    int placed = 0;
    while (probes < capacity && !placed) {
        if (table->map_ids[slot] == 0) {
            table->map_ids[slot] = id + 1;
            table->map_hashes[slot] = hash;
            placed = 1;
        } else {
            slot = it_bucket(slot + 1, capacity);
            probes += 1;
        }
    }
}

/* `intern-map-rebuild-prefix` + `intern-map-insert-existing!`: after doubling,
 * every live id is rehashed from its pool name and reinserted. */
static void it_grow(InternTable *table) {
    int64_t capacity = table->capacity * 2;
    int64_t count = table->count;
    for (int64_t i = 0; i < capacity; i += 1) {
        table->map_ids[i] = 0;
    }
    table->capacity = capacity;
    for (int64_t i = 0; i < count; i += 1) {
        int64_t hash =
            it_hash_words(table->names, table->name_off[i], table->name_len[i]);
        it_map_insert_from(table, i, hash, it_bucket(hash, capacity), capacity);
    }
}

/* `intern-slice`, the path `intern-source-slice` calls once per lexed symbol. */
static int64_t it_intern_slice(InternTable *table, const unsigned char *text,
                               int64_t start, int64_t len) {
    int64_t capacity = table->capacity;
    int64_t hash = it_hash_words(text, start, len);
    int64_t cursor = it_bucket(hash, capacity);
    int64_t steps = 0;
    int64_t out = -1;
    int done = 0;

    while (done ? 0 : steps < capacity) {
        int64_t stored = table->map_ids[cursor];
        if (stored == 0) {
            int64_t count = table->count;
            int64_t name_cursor = table->name_cursor;
            /* Miss: copy the slice into the persistent name pool, take the next
             * source id, then place it. Growth happens first so the placement
             * probe already runs at the final capacity. */
            for (int64_t i = 0; i < len; i += 1) {
                table->names[name_cursor + i] = text[start + i];
            }
            table->name_off[count] = name_cursor;
            table->name_len[count] = len;
            table->name_cursor = name_cursor + len;
            if ((count + 1) * 4 >= capacity * 3) {
                it_grow(table);
                capacity = table->capacity;
                cursor = it_bucket(hash, capacity);
            }
            table->count = count + 1;
            it_map_insert_from(table, count, hash, cursor, capacity);
            out = count;
            done = 1;
        } else {
            int64_t source_id = stored - 1;
            if (table->map_hashes[cursor] == hash &&
                it_slice_eq(table->names, table->name_off[source_id],
                            table->name_len[source_id], text, start, len)) {
                out = source_id;
                done = 1;
            } else {
                cursor = it_bucket(cursor + 1, capacity);
                steps += 1;
            }
        }
    }
    return out;
}

/* `intern-reset!`: clear the dedup table and the pool for a fresh compile. The
 * compiler clears its whole fixed map; the analogue here is the capacity the
 * previous round grew to. */
static void it_reset(InternTable *table) {
    int64_t capacity = table->capacity;
    for (int64_t i = 0; i < capacity; i += 1) {
        table->map_ids[i] = 0;
    }
    table->capacity = IT_INITIAL_CAPACITY;
    table->count = 0;
    table->name_cursor = 0;
}

/* One pass over the identifier stream, in encounter order. */
static uint64_t it_pass(InternTable *table, const unsigned char *text,
                        const int64_t *starts, const int64_t *lengths,
                        int64_t lines, uint64_t seed_acc) {
    uint64_t acc = seed_acc;
    for (int64_t k = 0; k < lines; k += 1) {
        int64_t id = it_intern_slice(table, text, starts[k], lengths[k]);
        acc = acc * 1000003u + (uint64_t)id * 2654435761u;
    }
    return acc;
}

static int64_t it_count_lines(const unsigned char *text, int64_t n) {
    int64_t lines = 0;
    for (int64_t i = 0; i < n; i += 1) {
        if (text[i] == 10) {
            lines += 1;
        }
    }
    return lines;
}

/* Index the newline-separated corpus into (start, length) slices without
 * copying: `intern-slice` takes a source buffer plus a range, exactly as the
 * lexer hands it the source text plus the token's extent. */
static int64_t it_index_lines(const unsigned char *text, int64_t n,
                              int64_t *starts, int64_t *lengths) {
    int64_t start = 0;
    int64_t lines = 0;
    for (int64_t i = 0; i < n; i += 1) {
        if (text[i] == 10) {
            starts[lines] = start;
            lengths[lines] = i - start;
            lines += 1;
            start = i + 1;
        }
    }
    return lines;
}

/* Preallocated map storage. Doubling stops as soon as
 * `(count + 1) * 4 < capacity * 3`, so the capacity can never exceed
 * `8 * (distinct + 1) / 3`, and there are never more distinct names than
 * lines. */
static int64_t it_map_storage(int64_t lines) {
    int64_t capacity = IT_INITIAL_CAPACITY;
    while (capacity < lines * 3) {
        capacity *= 2;
    }
    return capacity;
}

static void *it_alloc(size_t bytes) {
    void *items = calloc(bytes, 1);
    if (!items) {
        abort();
    }
    return items;
}

static uint64_t it_bench(const char *path, int64_t rounds) {
    FILE *handle = fopen(path, "rb");
    unsigned char *text = 0;
    long size = 0;
    int64_t n = 0;
    int64_t line_count = 0;
    int64_t lines = 0;
    int64_t storage = 0;
    int64_t *starts = 0;
    int64_t *lengths = 0;
    InternTable table;
    uint64_t acc = 0;

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
    text = (unsigned char *)it_alloc((size_t)size + 1);
    if (fread(text, 1, (size_t)size, handle) != (size_t)size) {
        abort();
    }
    fclose(handle);
    n = (int64_t)size;

    line_count = it_count_lines(text, n);
    starts = (int64_t *)it_alloc(((size_t)line_count + 1) * sizeof(int64_t));
    lengths = (int64_t *)it_alloc(((size_t)line_count + 1) * sizeof(int64_t));
    lines = it_index_lines(text, n, starts, lengths);
    storage = it_map_storage(lines);

    table.map_ids = (int64_t *)it_alloc((size_t)storage * sizeof(int64_t));
    table.map_hashes = (int64_t *)it_alloc((size_t)storage * sizeof(int64_t));
    table.names = (unsigned char *)it_alloc((size_t)n + 1);
    table.name_off = (int64_t *)it_alloc(((size_t)lines + 1) * sizeof(int64_t));
    table.name_len = (int64_t *)it_alloc(((size_t)lines + 1) * sizeof(int64_t));
    table.capacity = 0;
    table.count = 0;
    table.name_cursor = 0;

    for (int64_t round = 0; round < rounds; round += 1) {
        it_reset(&table);
        acc = it_pass(&table, text, starts, lengths, lines, acc);
        acc = it_pass(&table, text, starts, lengths, lines, acc);
    }

    free(text);
    free(starts);
    free(lengths);
    free(table.map_ids);
    free(table.map_hashes);
    free(table.names);
    free(table.name_off);
    free(table.name_len);
    return acc * 1000003u + (uint64_t)table.count;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)it_bench(path, rounds));
    return 0;
}
