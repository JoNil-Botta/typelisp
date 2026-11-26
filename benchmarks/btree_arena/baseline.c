/* benchmarks/btree_arena/baseline.c - clang C baseline for btree_arena.
 *
 * Equivalent to benchmarks/btree_arena/bench.tl: arena-backed order-16 B-tree
 * (max 15 keys, 16 children per node) with flat SoA arena reset per round,
 * proactive child splitting on insert, and mixed point lookups + recursive
 * range scans folded into a wrapping 64-bit FNV-1a checksum.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define BT_HASH_BASIS 0xcbf29ce484222325ULL
#define BT_HASH_PRIME 1099511628211ULL
#define BT_MAX_KEYS 15
#define BT_MID 7
#define BT_KEY_MASK 1048575ULL

typedef struct {
    int64_t root;
    int64_t node_count;
} TreeState;

static uint64_t bt_mix(uint64_t h, uint64_t v) {
    return (h ^ v) * BT_HASH_PRIME;
}

static uint64_t bt_splitmix(uint64_t x) {
    uint64_t z = x + 0x9e3779b97f4a7c15ULL;
    z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9ULL;
    z = (z ^ (z >> 27)) * 0x94d049bb133111ebULL;
    return z ^ (z >> 31);
}

static int64_t bt_alloc_node(TreeState *st, int64_t *nkeys, int64_t *leaf,
                             int64_t is_leaf) {
    int64_t id = st->node_count;
    st->node_count = id + 1;
    nkeys[id] = 0;
    leaf[id] = is_leaf;
    return id;
}

static int64_t bt_lower_bound(const int64_t *keys, int64_t base, int64_t n,
                              int64_t key) {
    int64_t lo = 0;
    int64_t hi = n;
    while (lo < hi) {
        int64_t mid = (lo + hi) >> 1;
        if (keys[base + mid] < key) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return lo;
}

static void bt_split_child(TreeState *st, int64_t *nkeys, int64_t *leaf,
                           int64_t *keys, int64_t *vals, int64_t *children,
                           int64_t parent, int64_t idx) {
    int64_t p_base = parent << 4;
    int64_t y = children[p_base + idx];
    int64_t y_base = y << 4;
    int64_t y_leaf = leaf[y];
    int64_t z = bt_alloc_node(st, nkeys, leaf, y_leaf);
    int64_t z_base = z << 4;
    int64_t pn = nkeys[parent];

    for (int64_t j = 0; j < BT_MID; j++) {
        keys[z_base + j] = keys[y_base + j + 8];
        vals[z_base + j] = vals[y_base + j + 8];
    }
    if (y_leaf == 0) {
        for (int64_t j = 0; j <= BT_MID; j++) {
            children[z_base + j] = children[y_base + j + 8];
        }
    }
    nkeys[z] = BT_MID;
    nkeys[y] = BT_MID;

    for (int64_t j = pn; j > idx; j--) {
        children[p_base + j + 1] = children[p_base + j];
    }
    children[p_base + idx + 1] = z;

    for (int64_t j = pn - 1; j >= idx; j--) {
        keys[p_base + j + 1] = keys[p_base + j];
        vals[p_base + j + 1] = vals[p_base + j];
    }
    keys[p_base + idx] = keys[y_base + BT_MID];
    vals[p_base + idx] = vals[y_base + BT_MID];
    nkeys[parent] = pn + 1;
}

static void bt_insert(TreeState *st, int64_t *nkeys, int64_t *leaf,
                      int64_t *keys, int64_t *vals, int64_t *children,
                      int64_t key, int64_t val) {
    if (nkeys[st->root] == BT_MAX_KEYS) {
        int64_t old_root = st->root;
        int64_t new_root = bt_alloc_node(st, nkeys, leaf, 0);
        children[new_root << 4] = old_root;
        st->root = new_root;
        bt_split_child(st, nkeys, leaf, keys, vals, children, new_root, 0);
    }
    int64_t x = st->root;
    for (;;) {
        int64_t x_base = x << 4;
        int64_t n = nkeys[x];
        int64_t pos = bt_lower_bound(keys, x_base, n, key);
        if (pos < n && keys[x_base + pos] == key) {
            vals[x_base + pos] = val;
            return;
        }
        if (leaf[x] == 1) {
            for (int64_t j = n - 1; j >= pos; j--) {
                keys[x_base + j + 1] = keys[x_base + j];
                vals[x_base + j + 1] = vals[x_base + j];
            }
            keys[x_base + pos] = key;
            vals[x_base + pos] = val;
            nkeys[x] = n + 1;
            return;
        }
        int64_t child = children[x_base + pos];
        if (nkeys[child] == BT_MAX_KEYS) {
            bt_split_child(st, nkeys, leaf, keys, vals, children, x, pos);
            int64_t pk = keys[x_base + pos];
            if (key == pk) {
                vals[x_base + pos] = val;
                return;
            }
            if (key > pk) {
                x = children[x_base + pos + 1];
            } else {
                x = children[x_base + pos];
            }
        } else {
            x = child;
        }
    }
}

static int64_t bt_find(const int64_t *nkeys, const int64_t *leaf,
                       const int64_t *keys, const int64_t *vals,
                       const int64_t *children, int64_t root, int64_t key) {
    int64_t x = root;
    for (;;) {
        int64_t x_base = x << 4;
        int64_t n = nkeys[x];
        int64_t pos = bt_lower_bound(keys, x_base, n, key);
        if (pos < n && keys[x_base + pos] == key) {
            return vals[x_base + pos];
        }
        if (leaf[x] == 1) {
            return -1;
        }
        x = children[x_base + pos];
    }
}

static uint64_t bt_range_scan(const int64_t *nkeys, const int64_t *leaf,
                              const int64_t *keys, const int64_t *vals,
                              const int64_t *children, int64_t node,
                              int64_t lo, int64_t hi, uint64_t acc) {
    int64_t base = node << 4;
    int64_t n = nkeys[node];
    int64_t is_leaf = leaf[node];
    int64_t i = bt_lower_bound(keys, base, n, lo);
    uint64_t h = acc;
    int stopped = 0;
    while (i < n && !stopped) {
        if (is_leaf == 0) {
            h = bt_range_scan(nkeys, leaf, keys, vals, children,
                              children[base + i], lo, hi, h);
        }
        int64_t k = keys[base + i];
        if (k > hi) {
            stopped = 1;
        } else {
            h = bt_mix(h, (uint64_t)k);
            h = bt_mix(h, (uint64_t)vals[base + i]);
            i += 1;
        }
    }
    if (!stopped && is_leaf == 0) {
        h = bt_range_scan(nkeys, leaf, keys, vals, children,
                          children[base + n], lo, hi, h);
    }
    return h;
}

static int64_t *bt_alloc_i64(int64_t n) {
    int64_t *p = (int64_t *)calloc((size_t)n, sizeof(int64_t));
    if (!p) abort();
    return p;
}

static uint64_t bt_bench(int64_t inserts, int64_t queries, int64_t rounds) {
    int64_t max_nodes = inserts + 64;
    int64_t *nkeys = bt_alloc_i64(max_nodes);
    int64_t *leaf = bt_alloc_i64(max_nodes);
    int64_t *keys = bt_alloc_i64(max_nodes << 4);
    int64_t *vals = bt_alloc_i64(max_nodes << 4);
    int64_t *children = bt_alloc_i64(max_nodes << 4);
    int64_t *inserted = bt_alloc_i64(inserts);

    uint64_t rng = 0x243f6a8885a308d3ULL;
    uint64_t acc = BT_HASH_BASIS;

    for (int64_t round = 0; round < rounds; round++) {
        TreeState st;
        st.root = 0;
        st.node_count = 0;
        st.root = bt_alloc_node(&st, nkeys, leaf, 1);

        for (int64_t i = 0; i < inserts; i++) {
            rng += 0x9e3779b97f4a7c15ULL;
            int64_t k = (int64_t)(bt_splitmix(rng) & BT_KEY_MASK);
            int64_t v = k * 3 + round;
            inserted[i] = k;
            bt_insert(&st, nkeys, leaf, keys, vals, children, k, v);
        }

        for (int64_t q = 0; q < queries; q++) {
            rng += 0x9e3779b97f4a7c15ULL;
            uint64_t draw = bt_splitmix(rng);
            if ((q & 3) == 0) {
                int64_t lo = (int64_t)(draw & BT_KEY_MASK);
                int64_t hi = lo + 4096;
                acc = bt_range_scan(nkeys, leaf, keys, vals, children, st.root,
                                    lo, hi, acc);
            } else {
                int64_t target;
                if ((q & 1) == 1) {
                    target = inserted[(int64_t)(draw & 2147483647ULL) % inserts];
                } else {
                    target = (int64_t)(draw & BT_KEY_MASK);
                }
                int64_t found = bt_find(nkeys, leaf, keys, vals, children,
                                        st.root, target);
                acc = bt_mix(acc, (uint64_t)found);
            }
        }
        acc = bt_mix(acc, (uint64_t)st.node_count);
    }

    free(nkeys);
    free(leaf);
    free(keys);
    free(vals);
    free(children);
    free(inserted);
    return acc;
}

int main(int argc, char **argv) {
    int64_t inserts = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t queries = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    int64_t rounds = argc > 3 ? strtoll(argv[3], 0, 10) : 0;
    printf("%" PRIu64 "\n", bt_bench(inserts, queries, rounds));
    return 0;
}
