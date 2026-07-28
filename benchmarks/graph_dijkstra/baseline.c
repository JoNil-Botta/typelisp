/* benchmarks/graph_dijkstra/baseline.c - clang C baseline for graph_dijkstra.
 *
 * Equivalent to benchmarks/graph_dijkstra/bench.tl: a deterministic LCG builds
 * one directed graph of `vertices` vertices in compressed sparse row form (an
 * offset array of length vertices + 1 plus target and weight arrays), each
 * vertex getting two to six out-edges with weights in [1, 2^20). Each round
 * runs Dijkstra from a round-dependent source and folds the sum of the reached
 * distances, taken modulo a prime, into a rolling accumulator.
 *
 * The priority queue is a hand-rolled array-based binary min-heap: 0-based,
 * parent (i - 1) / 2, children 2i + 1 and 2i + 2, sift-up after a push and
 * sift-down after moving the last element to the root. There is no decrease-key
 * operation; a relaxation that improves dist pushes a second entry for the same
 * vertex, and a `settled` flag makes the pop discard stale entries. The heap
 * therefore holds at most edges + 1 entries. Both implementations run exactly
 * this variant, so the two sides agree entry for entry.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the LCG product here is formed in
 * uint64_t so the C side wraps identically, and every other value in this
 * workload stays far inside 63 bits. The accumulator stays in [0, prime), so
 * the printed decimal matches TypeLisp's print of an i64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define GD_MODULUS 1000000007LL
/* Larger than any reachable distance in this graph family. */
#define GD_INFINITY 4611686018427387904LL
#define GD_WEIGHT_LIMIT 1048576LL
#define GD_MAX_DEGREE 6

/* 64-bit LCG. The state advances over the full word and every drawn value comes
 * from the high bits, whose period is much longer than the low bits'. */
static int64_t gd_next_state(int64_t state) {
    return (int64_t)((uint64_t)state * 6364136223846793005ULL +
                     1442695040888963407ULL);
}

static int64_t gd_draw(int64_t state) {
    return (state >> 33) & 2147483647LL;
}

static int64_t gd_build(int64_t *offsets, int64_t *targets, int64_t *weights,
                        int64_t vertices, int64_t seed) {
    int64_t state = seed;
    int64_t cursor = 0;
    for (int64_t v = 0; v < vertices; v += 1) {
        offsets[v] = cursor;
        state = gd_next_state(state);
        cursor = cursor + 2 + gd_draw(state) % 5;
    }
    offsets[vertices] = cursor;
    for (int64_t e = 0; e < cursor; e += 1) {
        state = gd_next_state(state);
        targets[e] = gd_draw(state) % vertices;
        state = gd_next_state(state);
        weights[e] = 1 + gd_draw(state) % (GD_WEIGHT_LIMIT - 1);
    }
    return cursor;
}

static void gd_swap(int64_t *xs, int64_t i, int64_t j) {
    int64_t tmp = xs[i];
    xs[i] = xs[j];
    xs[j] = tmp;
}

static int64_t gd_dijkstra(const int64_t *offsets, const int64_t *targets,
                           const int64_t *weights, int64_t *dist,
                           int64_t *settled, int64_t *heap_key,
                           int64_t *heap_node, int64_t vertices,
                           int64_t source) {
    int64_t heap_size = 0;
    int64_t total = 0;
    for (int64_t i = 0; i < vertices; i += 1) {
        dist[i] = GD_INFINITY;
        settled[i] = 0;
    }
    dist[source] = 0;
    heap_key[0] = 0;
    heap_node[0] = source;
    heap_size = 1;
    while (heap_size > 0) {
        int64_t top_key = heap_key[0];
        int64_t top_node = heap_node[0];
        int64_t slot = 0;
        int sifting = 1;
        heap_size = heap_size - 1;
        heap_key[0] = heap_key[heap_size];
        heap_node[0] = heap_node[heap_size];
        while (sifting) {
            int64_t left = slot * 2 + 1;
            int64_t right = slot * 2 + 2;
            int64_t best = slot;
            if (left < heap_size && heap_key[left] < heap_key[best]) {
                best = left;
            }
            if (right < heap_size && heap_key[right] < heap_key[best]) {
                best = right;
            }
            if (best == slot) {
                sifting = 0;
            } else {
                gd_swap(heap_key, slot, best);
                gd_swap(heap_node, slot, best);
                slot = best;
            }
        }
        if (settled[top_node] == 0) {
            int64_t e = offsets[top_node];
            int64_t stop = offsets[top_node + 1];
            settled[top_node] = 1;
            while (e < stop) {
                int64_t next = targets[e];
                int64_t relaxed = top_key + weights[e];
                if (relaxed < dist[next]) {
                    int64_t child = heap_size;
                    dist[next] = relaxed;
                    heap_key[heap_size] = relaxed;
                    heap_node[heap_size] = next;
                    heap_size = heap_size + 1;
                    while (child > 0 &&
                           heap_key[(child - 1) / 2] > heap_key[child]) {
                        gd_swap(heap_key, child, (child - 1) / 2);
                        gd_swap(heap_node, child, (child - 1) / 2);
                        child = (child - 1) / 2;
                    }
                }
                e += 1;
            }
        }
    }
    for (int64_t i = 0; i < vertices; i += 1) {
        if (dist[i] < GD_INFINITY) {
            total = (total + dist[i]) % GD_MODULUS;
        }
    }
    return total;
}

static int64_t *gd_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static int64_t gd_bench(int64_t vertices, int64_t rounds) {
    int64_t *offsets = gd_alloc(vertices + 1);
    int64_t *targets = gd_alloc(vertices * GD_MAX_DEGREE);
    int64_t *weights = gd_alloc(vertices * GD_MAX_DEGREE);
    int64_t *dist = gd_alloc(vertices);
    int64_t *settled = gd_alloc(vertices);
    int64_t *heap_key = gd_alloc(vertices * GD_MAX_DEGREE + 2);
    int64_t *heap_node = gd_alloc(vertices * GD_MAX_DEGREE + 2);
    int64_t acc = 0;

    gd_build(offsets, targets, weights, vertices, 1);
    for (int64_t round = 0; round < rounds; round += 1) {
        acc = (acc * 31 +
               gd_dijkstra(offsets, targets, weights, dist, settled, heap_key,
                           heap_node, vertices, round % vertices)) %
              GD_MODULUS;
    }
    free(offsets);
    free(targets);
    free(weights);
    free(dist);
    free(settled);
    free(heap_key);
    free(heap_node);
    return acc;
}

int main(int argc, char **argv) {
    int64_t vertices = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)gd_bench(vertices, rounds));
    return 0;
}
