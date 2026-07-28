/* benchmarks/cfg_domloops/baseline.c - clang C baseline for cfg_domloops.
 *
 * Equivalent to benchmarks/cfg_domloops/bench.tl: the TypeLisp optimizer's own
 * per-function CFG analysis, run over real block graphs the compiler produced
 * while compiling itself (see README.md for the corpus).
 *
 * Mirrored compiler functions, all in src/compiler_optimize.tl:
 *   opt-cfg-index-build        -- dense block ids in block-list order, CSR
 *                                 successor and predecessor rows, DFS
 *                                 postorder, reverse postorder, RPO numbers
 *   opt-cfg-dominators-with    -- Cooper/Harvey/Kennedy iterative immediate
 *                                 dominators (RPO sweeps to a fixpoint, the
 *                                 two-finger opt-dom-intersect-idom walk) plus
 *                                 opt-dom-build-euler!'s tin/tout stamping
 *   opt-cfg-natural-loops-with-context -- back edges found by scanning blocks
 *                                 last to first, bodies collected backwards
 *                                 from the latch, single-outside-predecessor
 *                                 preheader detection
 *   opt-cfg-context-build      -- the composition of the three above
 *
 * The compiler's recursive DFS postorder and Euler tour are written here with
 * an explicit stack, which visits nodes in exactly the same order.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum here is formed in
 * uint64_t so the C side wraps identically, and every other value in this
 * workload stays far inside 63 bits. The printed decimal is the checksum
 * reinterpreted as a signed 64-bit integer, matching TypeLisp's print of an
 * i64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CFG_HASH_BASIS 1469598103934665603ULL
#define CFG_HASH_PRIME 1099511628211ULL

/* Parsed corpus tokens and the scratch arrays every per-function pass reuses.
 * File-scope state keeps the analysis functions parameterless, matching how the
 * compiler threads one workspace through a pass. */
static int64_t *cfg_tokens;
static int64_t *cfg_offsets;
static int64_t *cfg_succ_off;
static int64_t *cfg_succ_edge;
static int64_t *cfg_succ_fill;
static int64_t *cfg_pred_off;
static int64_t *cfg_pred_edge;
static int64_t *cfg_pred_fill;
static int64_t *cfg_child_off;
static int64_t *cfg_child_edge;
static int64_t *cfg_child_fill;
static int64_t *cfg_reachable;
static int64_t *cfg_postorder;
static int64_t *cfg_rpo;
static int64_t *cfg_rpo_num;
static int64_t *cfg_idom;
static int64_t *cfg_tin;
static int64_t *cfg_tout;
static int64_t *cfg_marks;
static int64_t *cfg_worklist;
static int64_t *cfg_stack_node;
static int64_t *cfg_stack_edge;

/* Per-function view of the corpus, set by cfg_bench before cfg_function runs. */
static int64_t cfg_blocks;
static int64_t cfg_edges;
static int64_t cfg_edge_base;
static int64_t cfg_reach_count;

static uint64_t cfg_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * CFG_HASH_PRIME;
}

static int64_t *cfg_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static char *cfg_read_file(const char *path, int64_t *length) {
    FILE *handle = fopen(path, "rb");
    char *text;
    long size;
    if (!handle) {
        abort();
    }
    if (fseek(handle, 0, SEEK_END) != 0) {
        abort();
    }
    size = ftell(handle);
    if (size < 0 || fseek(handle, 0, SEEK_SET) != 0) {
        abort();
    }
    text = (char *)malloc((size_t)size + 1);
    if (!text) {
        abort();
    }
    if (fread(text, 1, (size_t)size, handle) != (size_t)size) {
        abort();
    }
    text[size] = '\0';
    fclose(handle);
    *length = (int64_t)size;
    return text;
}

static int64_t cfg_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int cfg_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t cfg_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = cfg_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && cfg_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (cfg_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (cfg_digit(cfg_byte_at(text, n, i))) {
                value = value * 10 + (cfg_byte_at(text, n, i) - 48);
                i += 1;
            }
            out[count] = negative ? -value : value;
            count += 1;
        } else {
            i += 1;
        }
    }
    return count;
}

/* opt-cfg-csr-build for both directions. The corpus lists a block's successors
 * in the order opt-cfg-instr-successors discovers them, so counting sort
 * reproduces the compiler's successor rows exactly; predecessor rows come out
 * in ascending source order, which is the order opt-i64-list-add builds and
 * opt-cfg-csr-fill-rows! reverses back. */
static void cfg_build_csr(void) {
    int64_t count = cfg_blocks;
    int64_t succ_total = 0;
    int64_t pred_total = 0;
    int64_t i;
    int64_t edge;
    for (i = 0; i < count; i += 1) {
        cfg_succ_fill[i] = 0;
        cfg_pred_fill[i] = 0;
    }
    for (edge = 0; edge < cfg_edges; edge += 1) {
        int64_t src = cfg_tokens[cfg_edge_base + edge * 2];
        int64_t dst = cfg_tokens[cfg_edge_base + edge * 2 + 1];
        cfg_succ_fill[src] += 1;
        cfg_pred_fill[dst] += 1;
    }
    for (i = 0; i < count; i += 1) {
        cfg_succ_off[i] = succ_total;
        succ_total += cfg_succ_fill[i];
        cfg_succ_fill[i] = cfg_succ_off[i];
        cfg_pred_off[i] = pred_total;
        pred_total += cfg_pred_fill[i];
        cfg_pred_fill[i] = cfg_pred_off[i];
    }
    cfg_succ_off[count] = succ_total;
    cfg_pred_off[count] = pred_total;
    for (edge = 0; edge < cfg_edges; edge += 1) {
        int64_t src = cfg_tokens[cfg_edge_base + edge * 2];
        int64_t dst = cfg_tokens[cfg_edge_base + edge * 2 + 1];
        cfg_succ_edge[cfg_succ_fill[src]] = dst;
        cfg_succ_fill[src] += 1;
        cfg_pred_edge[cfg_pred_fill[dst]] = src;
        cfg_pred_fill[dst] += 1;
    }
}

/* opt-cfg-index-dfs-postorder! written with an explicit stack: mark on entry,
 * append on exit, successors in CSR row order. */
static void cfg_dfs_postorder(void) {
    int64_t count = cfg_blocks;
    int64_t post = 0;
    int64_t sp = 0;
    int64_t i;
    for (i = 0; i < count; i += 1) {
        cfg_reachable[i] = 0;
        cfg_postorder[i] = -1;
        cfg_rpo[i] = -1;
        cfg_rpo_num[i] = -1;
    }
    if (count > 0) {
        cfg_reachable[0] = 1;
        cfg_stack_node[0] = 0;
        cfg_stack_edge[0] = cfg_succ_off[0];
        sp = 0;
        while (sp >= 0) {
            int64_t node = cfg_stack_node[sp];
            int64_t cursor = cfg_stack_edge[sp];
            if (cursor < cfg_succ_off[node + 1]) {
                int64_t next = cfg_succ_edge[cursor];
                cfg_stack_edge[sp] = cursor + 1;
                if (cfg_reachable[next] == 0) {
                    cfg_reachable[next] = 1;
                    sp += 1;
                    cfg_stack_node[sp] = next;
                    cfg_stack_edge[sp] = cfg_succ_off[next];
                }
            } else {
                cfg_postorder[post] = node;
                post += 1;
                sp -= 1;
            }
        }
    }
    cfg_reach_count = post;
    for (i = 0; i < post; i += 1) {
        cfg_rpo[i] = cfg_postorder[post - 1 - i];
    }
    for (i = 0; i < post; i += 1) {
        cfg_rpo_num[cfg_rpo[i]] = i;
    }
}

/* opt-dom-intersect-idom: walk both fingers up the partial dominator tree until
 * they meet, always advancing the one with the larger RPO number. */
static int64_t cfg_intersect(int64_t left, int64_t right) {
    int64_t a = left;
    int64_t b = right;
    while (a != b) {
        while (cfg_rpo_num[a] > cfg_rpo_num[b]) {
            a = cfg_idom[a];
        }
        while (cfg_rpo_num[b] > cfg_rpo_num[a]) {
            b = cfg_idom[b];
        }
    }
    return a;
}

static int64_t cfg_idom_from_preds(int64_t id) {
    int64_t edge = cfg_pred_off[id];
    int64_t end = cfg_pred_off[id + 1];
    int64_t candidate = -1;
    while (edge < end) {
        int64_t pred = cfg_pred_edge[edge];
        if (cfg_reachable[pred] == 1 && cfg_idom[pred] >= 0) {
            if (candidate < 0) {
                candidate = pred;
            } else {
                candidate = cfg_intersect(pred, candidate);
            }
        }
        edge += 1;
    }
    return candidate;
}

static int cfg_idom_iterate(int64_t entry) {
    int64_t slot = 1;
    int changed = 0;
    while (slot < cfg_reach_count) {
        int64_t id = cfg_rpo[slot];
        int64_t next = cfg_idom_from_preds(id);
        if (id != entry && next >= 0 && cfg_idom[id] != next) {
            cfg_idom[id] = next;
            changed = 1;
        }
        slot += 1;
    }
    return changed;
}

/* opt-dom-build-euler!: dominator-tree children in ascending id order, then a
 * DFS stamping tin on entry and tout on exit. */
static void cfg_build_euler(int64_t entry) {
    int64_t count = cfg_blocks;
    int64_t total = 0;
    int64_t time = 0;
    int64_t sp = 0;
    int64_t i;
    for (i = 0; i < count; i += 1) {
        cfg_tin[i] = -1;
        cfg_tout[i] = -1;
        cfg_child_fill[i] = 0;
    }
    for (i = 0; i < count; i += 1) {
        int64_t parent = cfg_idom[i];
        if (cfg_reachable[i] == 1 && parent >= 0 && parent != i) {
            cfg_child_fill[parent] += 1;
        }
    }
    for (i = 0; i < count; i += 1) {
        cfg_child_off[i] = total;
        total += cfg_child_fill[i];
        cfg_child_fill[i] = cfg_child_off[i];
    }
    cfg_child_off[count] = total;
    for (i = 0; i < count; i += 1) {
        int64_t parent = cfg_idom[i];
        if (cfg_reachable[i] == 1 && parent >= 0 && parent != i) {
            cfg_child_edge[cfg_child_fill[parent]] = i;
            cfg_child_fill[parent] += 1;
        }
    }
    if (count > 0 && cfg_reachable[entry] == 1) {
        cfg_stack_node[0] = entry;
        cfg_stack_edge[0] = cfg_child_off[entry];
        cfg_tin[entry] = 0;
        time = 1;
        sp = 0;
        while (sp >= 0) {
            int64_t node = cfg_stack_node[sp];
            int64_t cursor = cfg_stack_edge[sp];
            if (cursor < cfg_child_off[node + 1]) {
                int64_t child = cfg_child_edge[cursor];
                cfg_stack_edge[sp] = cursor + 1;
                cfg_tin[child] = time;
                time += 1;
                sp += 1;
                cfg_stack_node[sp] = child;
                cfg_stack_edge[sp] = cfg_child_off[child];
            } else {
                cfg_tout[node] = time;
                sp -= 1;
            }
        }
    }
}

/* opt-dom-info-dominates-id? */
static int cfg_dominates(int64_t dominator, int64_t label) {
    if (cfg_reachable[dominator] == 1 && cfg_reachable[label] == 1) {
        return cfg_tin[dominator] >= 0 && cfg_tin[label] >= 0 &&
               cfg_tin[dominator] <= cfg_tin[label] &&
               cfg_tout[label] <= cfg_tout[dominator];
    }
    return 0;
}

/* opt-natural-loop-build's body collection: seed the marks with header and
 * latch, then walk predecessors backwards from the latch only (a self loop
 * expands nothing), taking the most recently added label first. */
static int64_t cfg_loop_body(int64_t header, int64_t latch) {
    int64_t count = cfg_blocks;
    int64_t size = 0;
    int64_t pending = 0;
    int64_t i;
    for (i = 0; i < count; i += 1) {
        cfg_marks[i] = 0;
    }
    cfg_marks[header] = 1;
    cfg_marks[latch] = 1;
    size = 1;
    if (header != latch) {
        size = 2;
        cfg_worklist[0] = latch;
        pending = 1;
    }
    while (pending > 0) {
        int64_t node = cfg_worklist[pending - 1];
        int64_t edge;
        int64_t end;
        pending -= 1;
        edge = cfg_pred_off[node];
        end = cfg_pred_off[node + 1];
        while (edge < end) {
            int64_t pred = cfg_pred_edge[edge];
            if (cfg_reachable[pred] == 1 && cfg_marks[pred] == 0) {
                cfg_marks[pred] = 1;
                size += 1;
                cfg_worklist[pending] = pred;
                pending += 1;
            }
            edge += 1;
        }
    }
    return size;
}

/* opt-natural-loop-find-preheader: the loop has a preheader when exactly one
 * reachable predecessor of the header lies outside the body and its only
 * successor is the header. */
static int64_t cfg_loop_preheader(int64_t header) {
    int64_t edge = cfg_pred_off[header];
    int64_t end = cfg_pred_off[header + 1];
    int64_t state = 0;
    int64_t found = -1;
    while (edge < end) {
        int64_t pred = cfg_pred_edge[edge];
        if (cfg_reachable[pred] == 1 && cfg_marks[pred] == 0) {
            if (state == 2) {
                /* already ambiguous */
            } else if (state == 0) {
                if (cfg_succ_off[pred + 1] - cfg_succ_off[pred] == 1 &&
                    cfg_succ_edge[cfg_succ_off[pred]] == header) {
                    state = 1;
                    found = pred;
                } else {
                    state = 2;
                }
            } else {
                state = 2;
            }
        }
        edge += 1;
    }
    return state == 1 ? found : -1;
}

/* opt-cfg-natural-loop-block-seq-csr: blocks last to first, each successor row
 * forward; a reachable successor that dominates its source closes a loop. */
static uint64_t cfg_natural_loops(uint64_t seed) {
    uint64_t hash = seed;
    int64_t pos = cfg_blocks - 1;
    int64_t loops = 0;
    while (pos >= 0) {
        if (cfg_reachable[pos] == 1) {
            int64_t edge = cfg_succ_off[pos];
            int64_t end = cfg_succ_off[pos + 1];
            while (edge < end) {
                int64_t header = cfg_succ_edge[edge];
                if (cfg_reachable[header] == 1 && cfg_dominates(header, pos)) {
                    int64_t size = cfg_loop_body(header, pos);
                    int64_t preheader = cfg_loop_preheader(header);
                    hash = cfg_mix(hash, header);
                    hash = cfg_mix(hash, pos);
                    hash = cfg_mix(hash, size);
                    hash = cfg_mix(hash, preheader);
                    loops += 1;
                }
                edge += 1;
            }
        }
        pos -= 1;
    }
    return cfg_mix(hash, loops);
}

/* One function's opt-cfg-context-build plus natural-loop enumeration, folded
 * into a checksum over the RPO order, the idom vector, and every loop. */
static uint64_t cfg_function(void) {
    int64_t count = cfg_blocks;
    uint64_t hash = CFG_HASH_BASIS;
    int64_t remaining = 0;
    int64_t i;
    cfg_build_csr();
    cfg_dfs_postorder();
    for (i = 0; i < count; i += 1) {
        cfg_idom[i] = -1;
    }
    if (count > 0 && cfg_reachable[0] == 1) {
        cfg_idom[0] = 0;
        remaining = count + 1;
        while (remaining > 0 && cfg_idom_iterate(0)) {
            remaining -= 1;
        }
    }
    cfg_build_euler(0);
    hash = cfg_mix(hash, count);
    hash = cfg_mix(hash, cfg_reach_count);
    for (i = 0; i < cfg_reach_count; i += 1) {
        hash = cfg_mix(hash, cfg_rpo[i]);
    }
    for (i = 0; i < count; i += 1) {
        hash = cfg_mix(hash, cfg_idom[i]);
    }
    return cfg_natural_loops(hash);
}

static int64_t cfg_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = cfg_read_file(path, &length);
    int64_t capacity = length / 2 + 8;
    int64_t functions;
    int64_t cursor = 1;
    int64_t max_blocks = 1;
    int64_t max_edges = 1;
    int64_t round = 0;
    int64_t start = 0;
    uint64_t acc = CFG_HASH_BASIS;
    int64_t f;

    cfg_tokens = cfg_alloc(capacity);
    acc = cfg_mix(acc, cfg_scan_ints(text, length, cfg_tokens));
    functions = cfg_tokens[0];
    cfg_offsets = cfg_alloc(functions + 1);
    for (f = 0; f < functions; f += 1) {
        int64_t blocks = cfg_tokens[cursor];
        int64_t edges = cfg_tokens[cursor + 1];
        cfg_offsets[f] = cursor;
        if (blocks > max_blocks) {
            max_blocks = blocks;
        }
        if (edges > max_edges) {
            max_edges = edges;
        }
        cursor += 2 + edges * 2;
    }

    cfg_succ_off = cfg_alloc(max_blocks + 1);
    cfg_succ_edge = cfg_alloc(max_edges + 1);
    cfg_succ_fill = cfg_alloc(max_blocks + 1);
    cfg_pred_off = cfg_alloc(max_blocks + 1);
    cfg_pred_edge = cfg_alloc(max_edges + 1);
    cfg_pred_fill = cfg_alloc(max_blocks + 1);
    cfg_child_off = cfg_alloc(max_blocks + 1);
    cfg_child_edge = cfg_alloc(max_blocks + 1);
    cfg_child_fill = cfg_alloc(max_blocks + 1);
    cfg_reachable = cfg_alloc(max_blocks + 1);
    cfg_postorder = cfg_alloc(max_blocks + 1);
    cfg_rpo = cfg_alloc(max_blocks + 1);
    cfg_rpo_num = cfg_alloc(max_blocks + 1);
    cfg_idom = cfg_alloc(max_blocks + 1);
    cfg_tin = cfg_alloc(max_blocks + 1);
    cfg_tout = cfg_alloc(max_blocks + 1);
    cfg_marks = cfg_alloc(max_blocks + 1);
    cfg_worklist = cfg_alloc(max_blocks + 1);
    cfg_stack_node = cfg_alloc(max_blocks + 2);
    cfg_stack_edge = cfg_alloc(max_blocks + 2);

    while (round < rounds) {
        int64_t step = 0;
        acc = cfg_mix(acc, round);
        while (step < functions) {
            int64_t index = start + step;
            int64_t offset;
            if (index >= functions) {
                index -= functions;
            }
            offset = cfg_offsets[index];
            cfg_blocks = cfg_tokens[offset];
            cfg_edges = cfg_tokens[offset + 1];
            cfg_edge_base = offset + 2;
            acc = cfg_mix(acc, (int64_t)cfg_function());
            step += 1;
        }
        start += 1;
        if (start >= functions) {
            start = 0;
        }
        round += 1;
    }
    free(text);
    return (int64_t)acc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)cfg_bench(path, rounds));
    return 0;
}
