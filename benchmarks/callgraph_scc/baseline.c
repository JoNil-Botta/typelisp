/* benchmarks/callgraph_scc/baseline.c - clang C baseline for callgraph_scc.
 *
 * Equivalent to benchmarks/callgraph_scc/bench.tl: the TypeLisp optimizer's
 * own whole-program inline preparation - the dense function index, the
 * cons-list call graph, the loop-depth-weighted reference census and the
 * iterative Tarjan SCC solve - run over real programs the compiler produced
 * while compiling itself (see README.md for the corpus).
 *
 * Mirrored compiler functions, all in src/compiler_optimize.tl:
 *   opt-function-index-capacity / -build / -fill-from / -slot-id
 *   opt-slot-list-contains? / -add / -count
 *   opt-callgraph-init-edges / -add-callee / -callees / -build-slots / -build
 *     / -callee-count
 *   opt-inline-census-depth-weight / -depth-clear! / -depth-edge! /
 *     -depth-ranges! / -depth-prefix! / -depths-build! / -depth-at
 *   opt-inline-census-bump-map / -add-ref / -add-address / -blocks /
 *     -function / -build
 *   opt-inline-census-refcount / -hot-refcount / -address-taken? /
 *     -absorb-class
 *   opt-scc-set-low-min! / -next-child-from / -next-child / -discover! /
 *     -frame-push! / -pop-component! / -copy-order / opt-scc-compute
 *   the stdlib/hashmap.tl generated i64 -> i64 map behind opt_i64_i64_map
 *
 * The cons list is the same index-linked node pool bench.tl uses (the compiler
 * boxes each Cons cell into the optimizer arena; the pool IS that arena, and a
 * round resets its bump cursor exactly as an arena rewind does). The two
 * multi-value returns opt-scc-discover! and opt-scc-pop-component! make are
 * single-variant payload enums in the compiler and in bench.tl, and structs
 * returned by value here. Every recursion the compiler writes as a recursion -
 * opt-slot-list-contains?, opt-slot-list-count, opt-scc-next-child-from - is a
 * recursion here too.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum here is formed in
 * uint64_t so the C side wraps identically, and every other value in this
 * workload stays far inside 62 bits (the corpus's name ids are masked to 62
 * bits by the exporter). The printed decimal is the checksum reinterpreted as
 * a signed 64-bit integer, matching TypeLisp's print of an i64.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define CG_HASH_BASIS 1469598103934665603ULL
#define CG_HASH_PRIME 1099511628211ULL
#define CG_MAP_HASH 6364136223846793005ULL

/* opt-scc-discover! reports (next index, node stack length) and
 * opt-scc-pop-component! reports (node stack length, member count) through a
 * single-variant payload enum. Both are kept in that shape here. */
typedef struct {
    int64_t next;
    int64_t stack_len;
} CgSccDiscoverState;

typedef struct {
    int64_t stack_len;
    int64_t members;
} CgSccPopState;

/* Parsed corpus tokens plus the directories the round driver indexes.
 * File-scope state keeps the pass functions parameterless, matching how the
 * compiler threads one workspace through the inline stage. */
static int64_t *cg_tokens;

/* Program directory. */
static int64_t cg_program_count;
static int64_t *cg_program_base;
static int64_t *cg_program_funcs;
static int64_t *cg_program_edges;
static int64_t *cg_program_sccs;

/* Function directory, flattened across programs. */
static int64_t *cg_func_name;
static int64_t *cg_func_blocks;
static int64_t *cg_func_edge_off;
static int64_t *cg_func_edges;
static int64_t *cg_func_ref_off;
static int64_t *cg_func_refs;

/* The four opt_i64_i64_map instances, as stdlib/hashmap.tl lays them out: one
 * interleaved slot array of (state, key, value) triples per map, plus a
 * four-word descriptor (base, capacity, len, growth-limit). State 0 is Empty,
 * 1 is Tombstone, 2 is Occupied. */
static int64_t *cg_map_slots;
static int64_t cg_map_desc[16];
static int64_t *cg_map_scratch_key;
static int64_t *cg_map_scratch_val;

/* OptCallGraph: one OptSlotList head per slot over an index-linked node pool. */
static int64_t *cg_graph_head;
static int64_t cg_graph_count;
static int64_t *cg_node_slot;
static int64_t *cg_node_next;
static int64_t cg_node_len;

/* opt-inline-census depth scratch and the current block's site weight. */
static int64_t *cg_depth_slots;
static int64_t cg_depth_count;
static int cg_depth_active;
static int64_t cg_site_weight = 1;

/* opt-scc-compute workspace. */
static int64_t *cg_scc_indices;
static int64_t *cg_scc_lowlink;
static unsigned char *cg_scc_on_stack;
static int64_t *cg_scc_of;
static int64_t *cg_scc_node_stack;
static int64_t *cg_scc_frame_slots;
static int64_t *cg_scc_frame_nexts;
static int64_t *cg_scc_order_scratch;
static int64_t *cg_scc_order;
static int64_t cg_scc_count;

/* The deduplicated call-graph edge total this round's opt-slot-list-add filter
 * produced, accumulated by the fold's per-slot callee count. */
static int64_t cg_fold_edges;

static uint64_t cg_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * CG_HASH_PRIME;
}

static int64_t *cg_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static unsigned char *cg_alloc_bool(int64_t count) {
    unsigned char *items =
        (unsigned char *)calloc((size_t)count, sizeof(unsigned char));
    if (!items) {
        abort();
    }
    return items;
}

static char *cg_read_file(const char *path, int64_t *length) {
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

static int64_t cg_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int cg_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t cg_scan_ints(const char *text, int64_t n) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = cg_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && cg_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (cg_digit(byte) || byte == 45) {
            int negative = byte == 45;
            uint64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (cg_digit(cg_byte_at(text, n, i))) {
                value = value * 10 + (uint64_t)(cg_byte_at(text, n, i) - 48);
                i += 1;
            }
            cg_tokens[count] = negative ? -(int64_t)value : (int64_t)value;
            count += 1;
        } else {
            i += 1;
        }
    }
    return count;
}

/* --- stdlib/hashmap.tl generated i64 -> i64 map ---------------------------
 * Map ids: 0 = OptFunctionNameIndex.ids, 1 = refcount, 2 = addrtaken,
 * 3 = hotcount. */
static int64_t cg_map_base(int64_t m) { return cg_map_desc[m * 4]; }

static int64_t cg_map_capacity(int64_t m) { return cg_map_desc[m * 4 + 1]; }

static int64_t cg_map_len(int64_t m) { return cg_map_desc[m * 4 + 2]; }

static int64_t cg_map_limit(int64_t m) { return cg_map_desc[m * 4 + 3]; }

static void cg_map_set_capacity(int64_t m, int64_t value) {
    cg_map_desc[m * 4 + 1] = value;
}

static void cg_map_set_len(int64_t m, int64_t value) {
    cg_map_desc[m * 4 + 2] = value;
}

static void cg_map_set_limit(int64_t m, int64_t value) {
    cg_map_desc[m * 4 + 3] = value;
}

/* `round-capacity`: the next power of two at or above a positive request. */
static int64_t cg_map_round_capacity(int64_t capacity) {
    int64_t rounded;
    if (capacity >= 1 && (capacity & (capacity - 1)) == 0) {
        return capacity;
    }
    rounded = 1;
    while (rounded < capacity) {
        rounded *= 2;
    }
    return rounded;
}

/* `growth-limit-for` for the scalar family: three quarters of the capacity. */
static int64_t cg_map_growth_limit_for(int64_t capacity) {
    return capacity - (capacity >> 2);
}

/* `clear-ref!`: every slot back to Empty, len 0, the cached limit restored.
 * A round re-initialises the maps rather than allocating new ones, which is
 * what `with-capacity`'s zeroed slot array costs the compiler per compile. */
static void cg_map_clear(int64_t m) {
    int64_t base = cg_map_base(m);
    int64_t cap = cg_map_capacity(m);
    int64_t index = 0;
    while (index < cap) {
        cg_map_slots[base + index * 3] = 0;
        index += 1;
    }
    cg_map_set_len(m, 0);
    cg_map_set_limit(m, cg_map_growth_limit_for(cap));
}

/* `with-capacity`, reusing the reserved region instead of allocating. */
static void cg_map_with_capacity(int64_t m, int64_t capacity) {
    cg_map_set_capacity(m, cg_map_round_capacity(capacity < 1 ? 1 : capacity));
    cg_map_clear(m);
}

/* `probe`: linear probing over a power-of-two capacity, reusing the first
 * tombstone for an absent key. A non-negative result is the occupied slot
 * index; -(index + 2) is the slot an insert would take. */
static int64_t cg_map_probe(int64_t m, int64_t key) {
    int64_t base = cg_map_base(m);
    int64_t cap = cg_map_capacity(m);
    int64_t mask = cap - 1;
    int64_t cursor = (int64_t)(((uint64_t)key * CG_MAP_HASH) & (uint64_t)mask);
    int64_t walked = 0;
    int64_t first = -1;
    int64_t found = -1;
    int done = 0;
    while (walked < cap && !done) {
        int64_t state = cg_map_slots[base + cursor * 3];
        if (state == 2) {
            if (cg_map_slots[base + cursor * 3 + 1] == key) {
                found = cursor;
                done = 1;
            } else {
                cursor = (cursor + 1) & mask;
                walked += 1;
            }
        } else if (state == 0) {
            found = -(2 + (first >= 0 ? first : cursor));
            done = 1;
        } else {
            if (first < 0) {
                first = cursor;
            }
            cursor = (cursor + 1) & mask;
            walked += 1;
        }
    }
    if (done) {
        return found;
    }
    return first >= 0 ? -(2 + first) : -1;
}

/* `needs-grow?`: the cached `len + deleted` threshold. */
static int cg_map_needs_grow(int64_t m) {
    return cg_map_len(m) >= cg_map_limit(m);
}

/* `grow!`: double the capacity and rehash every occupied slot. The census and
 * index maps hold at most one entry per function while their capacity is at
 * least twice the function count, so this never fires on this corpus; it is
 * kept because `needs-grow?` is on the insert path and the compiler's map
 * carries it. */
static void cg_map_grow(int64_t m) {
    int64_t base = cg_map_base(m);
    int64_t old_cap = cg_map_capacity(m);
    int64_t live = 0;
    int64_t index = 0;
    int64_t cap;
    int64_t mask;
    int64_t item = 0;
    while (index < old_cap) {
        if (cg_map_slots[base + index * 3] == 2) {
            cg_map_scratch_key[live] = cg_map_slots[base + index * 3 + 1];
            cg_map_scratch_val[live] = cg_map_slots[base + index * 3 + 2];
            live += 1;
        }
        index += 1;
    }
    cg_map_set_capacity(m, old_cap * 2);
    cg_map_clear(m);
    cap = cg_map_capacity(m);
    mask = cap - 1;
    while (item < live) {
        int64_t key = cg_map_scratch_key[item];
        int64_t cursor =
            (int64_t)(((uint64_t)key * CG_MAP_HASH) & (uint64_t)mask);
        while (cg_map_slots[base + cursor * 3] == 2) {
            cursor = (cursor + 1) & mask;
        }
        cg_map_slots[base + cursor * 3] = 2;
        cg_map_slots[base + cursor * 3 + 1] = key;
        cg_map_slots[base + cursor * 3 + 2] = cg_map_scratch_val[item];
        cg_map_set_len(m, cg_map_len(m) + 1);
        item += 1;
    }
}

/* `insert-ref!`: the grow test runs once before the probe, and reusing a
 * tombstone gives the cached limit its slot back. */
static void cg_map_insert_ref(int64_t m, int64_t key, int64_t value) {
    int64_t base;
    int64_t slot;
    if (cg_map_needs_grow(m)) {
        cg_map_grow(m);
    }
    base = cg_map_base(m);
    slot = cg_map_probe(m, key);
    if (slot >= 0) {
        cg_map_slots[base + slot * 3 + 2] = value;
    } else {
        int64_t index = -slot - 2;
        if (cg_map_slots[base + index * 3] == 1) {
            cg_map_set_limit(m, cg_map_limit(m) + 1);
        }
        cg_map_slots[base + index * 3] = 2;
        cg_map_slots[base + index * 3 + 1] = key;
        cg_map_slots[base + index * 3 + 2] = value;
        cg_map_set_len(m, cg_map_len(m) + 1);
    }
}

/* `get` / `get-value-or`. */
static int64_t cg_map_get_value_or(int64_t m, int64_t key, int64_t fallback) {
    int64_t slot = cg_map_probe(m, key);
    if (slot >= 0) {
        return cg_map_slots[cg_map_base(m) + slot * 3 + 2];
    }
    return fallback;
}

/* `contains?`. */
static int cg_map_contains(int64_t m, int64_t key) {
    return cg_map_probe(m, key) >= 0;
}

/* --- opt-function-index --------------------------------------------------- */
static int64_t cg_function_index_capacity(int64_t count) {
    return count < 4 ? 8 : count * 2;
}

/* opt-function-index-fill-from: slot `index` claims the function at `index`,
 * and its name id maps to that slot. */
static void cg_function_index_fill_from(int64_t base, int64_t count) {
    int64_t index = 0;
    while (index < count) {
        cg_map_insert_ref(0, cg_func_name[base + index], index);
        index += 1;
    }
}

static void cg_function_index_build(int64_t base, int64_t count) {
    cg_map_with_capacity(0, cg_function_index_capacity(count));
    cg_function_index_fill_from(base, count);
}

/* opt-function-index-slot-id: a negative name id is "no symbol". -1 is None. */
static int64_t cg_function_index_slot_id(int64_t name_id) {
    if (name_id < 0) {
        return -1;
    }
    return cg_map_get_value_or(0, name_id, -1);
}

/* --- OptSlotList ----------------------------------------------------------
 * -1 is Nil; any other head is a node-pool index. */
static int cg_slot_list_contains(int64_t slots, int64_t slot) {
    if (slots < 0) {
        return 0;
    }
    if (cg_node_slot[slots] == slot) {
        return 1;
    }
    return cg_slot_list_contains(cg_node_next[slots], slot);
}

static int64_t cg_slot_list_add(int64_t slots, int64_t slot) {
    int64_t node;
    if (cg_slot_list_contains(slots, slot)) {
        return slots;
    }
    node = cg_node_len;
    cg_node_slot[node] = slot;
    cg_node_next[node] = slots;
    cg_node_len = node + 1;
    return node;
}

static int64_t cg_slot_list_count(int64_t slots) {
    if (slots < 0) {
        return 0;
    }
    return 1 + cg_slot_list_count(cg_node_next[slots]);
}

/* --- opt-callgraph -------------------------------------------------------- */
static int64_t cg_callgraph_add_callee(int64_t callees, int64_t name_id) {
    int64_t slot = cg_function_index_slot_id(name_id);
    if (slot >= 0) {
        return cg_slot_list_add(callees, slot);
    }
    return callees;
}

/* opt-callgraph-instr over one function's references: only a Call, TailCall,
 * CallCAbiStoreResult or SpmdCall callee (kind 0) becomes an edge. */
static int64_t cg_callgraph_callees(int64_t func) {
    int64_t cursor = cg_func_ref_off[func];
    int64_t end = cg_func_ref_off[func] + cg_func_refs[func] * 3;
    int64_t callees = -1;
    while (cursor < end) {
        if (cg_tokens[cursor + 2] == 0) {
            callees = cg_callgraph_add_callee(callees, cg_tokens[cursor + 1]);
        }
        cursor += 3;
    }
    return callees;
}

static void cg_callgraph_init_edges(int64_t count) {
    int64_t slot = 0;
    while (slot < count) {
        cg_graph_head[slot] = -1;
        slot += 1;
    }
}

static void cg_callgraph_build_slots(int64_t base, int64_t count) {
    int64_t slot = 0;
    while (slot < count) {
        cg_graph_head[slot] = cg_callgraph_callees(base + slot);
        slot += 1;
    }
}

static void cg_callgraph_build(int64_t base, int64_t count) {
    cg_node_len = 0;
    cg_graph_count = count;
    cg_callgraph_init_edges(count);
    cg_callgraph_build_slots(base, count);
}

static int64_t cg_callgraph_callee_count(int64_t from_slot) {
    if (from_slot < 0 || from_slot >= cg_graph_count) {
        return -1;
    }
    return cg_slot_list_count(cg_graph_head[from_slot]);
}

/* --- opt-inline-census: the block-order loop-depth estimate --------------- */
static int64_t cg_census_depth_base(void) { return 8; }

static int64_t cg_census_depth_cap(void) { return 2; }

static int64_t cg_census_depth_weight(int64_t depth) {
    int64_t capped = depth > cg_census_depth_cap() ? cg_census_depth_cap()
                                                   : depth;
    int64_t weight = 1;
    int64_t level = 0;
    while (level < capped) {
        weight *= cg_census_depth_base();
        level += 1;
    }
    return weight;
}

static void cg_census_depth_clear(int64_t count) {
    int64_t i = 0;
    while (i < count) {
        cg_depth_slots[i] = 0;
        i += 1;
    }
}

/* One edge. Only a target at or before the source opens a loop; the furthest
 * latch wins so several back edges into one header stay one nesting level.
 * `target` is the dense block index the label table would have returned. */
static int cg_census_depth_edge(int64_t target, int64_t source) {
    int64_t id = target;
    if (id >= 0 && id <= source) {
        int64_t end = source + 1;
        int64_t previous = cg_depth_slots[id];
        if (end > previous) {
            cg_depth_slots[id] = end;
        }
        return 1;
    }
    return 0;
}

static void cg_census_depth_prefix(int64_t count) {
    int64_t i = 1;
    while (i < count) {
        cg_depth_slots[i] = cg_depth_slots[i] + cg_depth_slots[i - 1];
        i += 1;
    }
}

/* Header -> furthest-latch records become range deltas. Descending order lets
 * this reuse the same array. */
static void cg_census_depth_ranges(int64_t count) {
    int64_t i = count - 1;
    while (i >= 0) {
        int64_t end = cg_depth_slots[i];
        cg_depth_slots[i] = 0;
        if (end > i) {
            cg_depth_slots[i] = cg_depth_slots[i] + 1;
            cg_depth_slots[end] = cg_depth_slots[end] - 1;
        }
        i -= 1;
    }
}

/* opt-inline-census-depth-mark! over one function's terminator edges, in block
 * order. A body with no back edge leaves the estimate inactive. */
static void cg_census_depths_build(int64_t func) {
    int64_t count = cg_func_blocks[func];
    cg_depth_active = 0;
    cg_depth_count = 0;
    cg_site_weight = 1;
    if (count >= 2) {
        int64_t cursor = cg_func_edge_off[func];
        int64_t end = cg_func_edge_off[func] + cg_func_edges[func] * 2;
        int found = 0;
        cg_census_depth_clear(count + 1);
        while (cursor < end) {
            if (cg_census_depth_edge(cg_tokens[cursor + 1], cg_tokens[cursor])) {
                found = 1;
            }
            cursor += 2;
        }
        if (found) {
            cg_census_depth_ranges(count);
            cg_census_depth_prefix(count);
            cg_depth_count = count;
            cg_depth_active = 1;
        }
    }
}

static int64_t cg_census_depth_at(int64_t position) {
    if (cg_depth_active && position < cg_depth_count) {
        return cg_depth_slots[position];
    }
    return 0;
}

/* --- opt-inline-census: the three counters -------------------------------- */
static void cg_census_bump_map(int64_t m, int64_t slot, int64_t amount) {
    int64_t count = cg_map_get_value_or(m, slot, -1);
    if (count >= 0) {
        cg_map_insert_ref(m, slot, count + amount);
    } else {
        cg_map_insert_ref(m, slot, amount);
    }
}

static void cg_census_add_ref(int64_t name_id) {
    int64_t slot = cg_function_index_slot_id(name_id);
    if (slot >= 0) {
        cg_census_bump_map(1, slot, 1);
        cg_census_bump_map(3, slot, cg_site_weight);
    }
}

static void cg_census_add_address(int64_t name_id) {
    int64_t slot = cg_function_index_slot_id(name_id);
    if (slot >= 0) {
        cg_map_insert_ref(2, slot, 1);
    }
}

/* opt-inline-census-blocks: every block installs its own site weight before
 * its instructions are walked, whether or not it holds a reference. */
static void cg_census_blocks(int64_t func) {
    int64_t blocks = cg_func_blocks[func];
    int64_t cursor = cg_func_ref_off[func];
    int64_t end = cg_func_ref_off[func] + cg_func_refs[func] * 3;
    int64_t position = 0;
    while (position < blocks) {
        cg_site_weight = cg_census_depth_weight(cg_census_depth_at(position));
        while (cursor < end && cg_tokens[cursor] == position) {
            if (cg_tokens[cursor + 2] == 0) {
                cg_census_add_ref(cg_tokens[cursor + 1]);
            } else {
                cg_census_add_address(cg_tokens[cursor + 1]);
            }
            cursor += 3;
        }
        position += 1;
    }
}

static void cg_census_function(int64_t func) {
    cg_census_depths_build(func);
    cg_census_blocks(func);
}

static void cg_census_build(int64_t base, int64_t count) {
    int64_t capacity = cg_function_index_capacity(count);
    int64_t position = 0;
    cg_map_with_capacity(1, capacity);
    cg_map_with_capacity(2, capacity);
    cg_map_with_capacity(3, capacity);
    while (position < count) {
        cg_census_function(base + position);
        position += 1;
    }
}

static int64_t cg_census_refcount(int64_t name_id) {
    int64_t slot = cg_function_index_slot_id(name_id);
    if (slot >= 0) {
        return cg_map_get_value_or(1, slot, 0);
    }
    return 0;
}

static int64_t cg_census_hot_refcount(int64_t name_id) {
    int64_t slot = cg_function_index_slot_id(name_id);
    if (slot >= 0) {
        return cg_map_get_value_or(3, slot, 0);
    }
    return 0;
}

static int cg_census_address_taken(int64_t name_id) {
    int64_t slot = cg_function_index_slot_id(name_id);
    if (slot >= 0) {
        return cg_map_contains(2, slot);
    }
    return 0;
}

static int64_t cg_inline_dup_max_refcount(void) { return 2; }

/* opt-inline-census-absorb-class, minus the `main` name test the corpus cannot
 * trigger. */
static int64_t cg_census_absorb_class(int64_t caller_name, int64_t callee_name) {
    int64_t refs = cg_census_refcount(callee_name);
    if (refs < 1 || refs > cg_inline_dup_max_refcount() ||
        caller_name == callee_name || cg_census_address_taken(callee_name)) {
        return 0;
    }
    return refs;
}

/* --- opt-scc-compute ------------------------------------------------------ */
static void cg_scc_set_low_min(int64_t slot, int64_t candidate) {
    int64_t old = cg_scc_lowlink[slot];
    if (candidate < old) {
        cg_scc_lowlink[slot] = candidate;
    }
}

/* The NEXT child is the smallest slot greater than `after`, found by scanning
 * the whole cons list every step. That quadratic walk is the compiler's real
 * cost and is kept. */
static int64_t cg_scc_next_child_from(int64_t slots, int64_t after,
                                      int64_t best) {
    int64_t slot;
    if (slots < 0) {
        return best;
    }
    slot = cg_node_slot[slots];
    return cg_scc_next_child_from(
        cg_node_next[slots], after,
        (slot > after && (best < 0 || slot < best)) ? slot : best);
}

static int64_t cg_scc_next_child(int64_t slot, int64_t after) {
    if (slot < 0 || slot >= cg_graph_count) {
        return -1;
    }
    return cg_scc_next_child_from(cg_graph_head[slot], after, -1);
}

static CgSccDiscoverState cg_scc_discover(int64_t slot, int64_t node_stack_len,
                                          int64_t next_index) {
    CgSccDiscoverState out;
    cg_scc_indices[slot] = next_index;
    cg_scc_lowlink[slot] = next_index;
    cg_scc_on_stack[slot] = 1;
    cg_scc_node_stack[node_stack_len] = slot;
    out.next = next_index + 1;
    out.stack_len = node_stack_len + 1;
    return out;
}

static int64_t cg_scc_frame_push(int64_t frame_len, int64_t slot) {
    cg_scc_frame_slots[frame_len] = slot;
    cg_scc_frame_nexts[frame_len] = -1;
    return frame_len + 1;
}

static CgSccPopState cg_scc_pop_component(int64_t node_stack_len, int64_t root,
                                          int64_t scc_id) {
    CgSccPopState out;
    int64_t len = node_stack_len;
    int done = 0;
    int64_t members = 0;
    while (!done) {
        int64_t next_len = len - 1;
        int64_t slot = cg_scc_node_stack[next_len];
        len = next_len;
        cg_scc_on_stack[slot] = 0;
        cg_scc_of[slot] = scc_id;
        members += 1;
        if (slot == root) {
            done = 1;
        }
    }
    out.stack_len = len;
    out.members = members;
    return out;
}

static void cg_scc_copy_order(int64_t count) {
    int64_t index = 0;
    while (index < count) {
        cg_scc_order[index] = cg_scc_order_scratch[index];
        index += 1;
    }
}

/* opt-cfg-fill-i64!, the pre-pass opt-scc-compute runs over four of its
 * arrays. */
static void cg_scc_fill_i64(int64_t *target, int64_t count) {
    int64_t index = 0;
    while (index < count) {
        target[index] = -1;
        index += 1;
    }
}

static void cg_scc_compute(int64_t count) {
    int64_t root = 0;
    int64_t next_index = 0;
    int64_t node_stack_len = 0;
    int64_t frame_len = 0;
    int64_t scc_count = 0;
    int64_t i = 0;
    cg_scc_fill_i64(cg_scc_indices, count);
    cg_scc_fill_i64(cg_scc_lowlink, count);
    cg_scc_fill_i64(cg_scc_of, count);
    cg_scc_fill_i64(cg_scc_order_scratch, count);
    while (i < count) {
        cg_scc_on_stack[i] = 0;
        i += 1;
    }
    while (root < count) {
        if (cg_scc_indices[root] == -1) {
            CgSccDiscoverState state =
                cg_scc_discover(root, node_stack_len, next_index);
            next_index = state.next;
            node_stack_len = state.stack_len;
            frame_len = cg_scc_frame_push(frame_len, root);
            while (frame_len > 0) {
                int64_t frame_index = frame_len - 1;
                int64_t slot = cg_scc_frame_slots[frame_index];
                int64_t child =
                    cg_scc_next_child(slot, cg_scc_frame_nexts[frame_index]);
                if (child >= 0) {
                    cg_scc_frame_nexts[frame_index] = child;
                    if (cg_scc_indices[child] == -1) {
                        CgSccDiscoverState down =
                            cg_scc_discover(child, node_stack_len, next_index);
                        next_index = down.next;
                        node_stack_len = down.stack_len;
                        frame_len = cg_scc_frame_push(frame_len, child);
                    } else if (cg_scc_on_stack[child]) {
                        cg_scc_set_low_min(slot, cg_scc_indices[child]);
                    }
                } else {
                    if (cg_scc_lowlink[slot] == cg_scc_indices[slot]) {
                        CgSccPopState popped =
                            cg_scc_pop_component(node_stack_len, slot,
                                                 scc_count);
                        node_stack_len = popped.stack_len;
                        cg_scc_order_scratch[scc_count] = scc_count;
                        scc_count += 1;
                    }
                    frame_len -= 1;
                    if (frame_len > 0) {
                        cg_scc_set_low_min(cg_scc_frame_slots[frame_len - 1],
                                           cg_scc_lowlink[slot]);
                    }
                }
            }
        }
        root += 1;
    }
    cg_scc_count = scc_count;
    cg_scc_copy_order(scc_count);
}

/* --- fold and self-check --------------------------------------------------
 * Everything an inline site reads back, once per slot: the SCC id and the
 * bottom-up order, the callee count, the raw and loop-weighted reference
 * counts, and the absorb class of this slot's name seen from its successor's.
 */
static uint64_t cg_program_fold(int64_t base, int64_t count, int64_t start,
                                uint64_t seed) {
    uint64_t hash = seed;
    int64_t edges = 0;
    int64_t step = 0;
    int64_t index = 0;
    while (step < count) {
        int64_t raw = start + step;
        int64_t slot = raw >= count ? raw - count : raw;
        int64_t name = cg_func_name[base + slot];
        int64_t caller =
            cg_func_name[base + (slot + 1 >= count ? 0 : slot + 1)];
        int64_t callees = cg_callgraph_callee_count(slot);
        edges += callees;
        hash = cg_mix(hash, cg_scc_of[slot]);
        hash = cg_mix(hash, callees);
        hash = cg_mix(hash, cg_census_refcount(name));
        hash = cg_mix(hash, cg_census_hot_refcount(name));
        hash = cg_mix(hash, cg_census_absorb_class(caller, name));
        step += 1;
    }
    while (index < cg_scc_count) {
        hash = cg_mix(hash, cg_scc_order[index]);
        index += 1;
    }
    cg_fold_edges = edges;
    return cg_mix(hash, edges);
}

/* Both structural quantities the exporter computed independently, checked
 * against this round's own tables and folded in. The TypeLisp side reports a
 * failure with io.panic, which writes to stderr and exits 134. */
static uint64_t cg_self_check(int64_t program) {
    if (cg_fold_edges != cg_program_edges[program]) {
        fputs("callgraph_scc: call-graph edge count self-check failed\n",
              stderr);
        exit(134);
    }
    if (cg_scc_count != cg_program_sccs[program]) {
        fputs("callgraph_scc: SCC count self-check failed\n", stderr);
        exit(134);
    }
    return cg_mix(cg_mix(CG_HASH_BASIS, cg_program_edges[program]),
                  cg_program_sccs[program]);
}

static int64_t cg_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = cg_read_file(path, &length);
    int64_t capacity = (length >> 1) + 8;
    int64_t tokens;
    int64_t programs;
    int64_t total_funcs = 0;
    int64_t max_funcs = 1;
    int64_t max_blocks = 1;
    int64_t max_nodes = 1;
    int64_t cursor;
    uint64_t acc = CG_HASH_BASIS;
    int64_t round = 0;
    int64_t program = 0;
    int64_t start = 0;
    int64_t p;
    int64_t next_func = 0;
    int64_t cap;
    int64_t i;

    cg_tokens = cg_alloc(capacity);
    tokens = cg_scan_ints(text, length);
    acc = cg_mix(acc, tokens);
    acc = cg_mix(acc, cg_tokens[0]);
    programs = cg_tokens[1];
    cg_program_count = programs;
    cg_program_base = cg_alloc(programs + 1);
    cg_program_funcs = cg_alloc(programs + 1);
    cg_program_edges = cg_alloc(programs + 1);
    cg_program_sccs = cg_alloc(programs + 1);

    /* First pass: count functions so the directories can be sized once. */
    cursor = 2;
    for (p = 0; p < programs; p += 1) {
        int64_t count = cg_tokens[cursor];
        int64_t f;
        total_funcs += count;
        if (count > max_funcs) {
            max_funcs = count;
        }
        cursor += 3;
        for (f = 0; f < count; f += 1) {
            cursor += 4 + cg_tokens[cursor + 2] * 2 + cg_tokens[cursor + 3] * 3;
        }
    }

    cg_func_name = cg_alloc(total_funcs + 1);
    cg_func_blocks = cg_alloc(total_funcs + 1);
    cg_func_edge_off = cg_alloc(total_funcs + 1);
    cg_func_edges = cg_alloc(total_funcs + 1);
    cg_func_ref_off = cg_alloc(total_funcs + 1);
    cg_func_refs = cg_alloc(total_funcs + 1);

    /* Second pass: fill the directories. */
    cursor = 2;
    for (p = 0; p < programs; p += 1) {
        int64_t count = cg_tokens[cursor];
        int64_t f;
        cg_program_base[p] = next_func;
        cg_program_funcs[p] = count;
        cg_program_edges[p] = cg_tokens[cursor + 1];
        cg_program_sccs[p] = cg_tokens[cursor + 2];
        cursor += 3;
        for (f = 0; f < count; f += 1) {
            int64_t blocks = cg_tokens[cursor + 1];
            int64_t edges = cg_tokens[cursor + 2];
            int64_t refs = cg_tokens[cursor + 3];
            cg_func_name[next_func] = cg_tokens[cursor];
            cg_func_blocks[next_func] = blocks;
            cg_func_edge_off[next_func] = cursor + 4;
            cg_func_edges[next_func] = edges;
            cg_func_ref_off[next_func] = cursor + 4 + edges * 2;
            cg_func_refs[next_func] = refs;
            if (blocks > max_blocks) {
                max_blocks = blocks;
            }
            max_nodes += refs;
            cursor += 4 + edges * 2 + refs * 3;
            next_func += 1;
        }
    }

    /* Scratch reserved once at the corpus maximum and reused every round. */
    cap = cg_map_round_capacity(cg_function_index_capacity(max_funcs));
    cg_map_slots = cg_alloc(cap * 24);
    cg_map_scratch_key = cg_alloc(cap + 1);
    cg_map_scratch_val = cg_alloc(cap + 1);
    for (i = 0; i < 4; i += 1) {
        cg_map_desc[i * 4] = i * (cap * 6);
    }
    cg_graph_head = cg_alloc(max_funcs + 1);
    cg_node_slot = cg_alloc(max_nodes + 1);
    cg_node_next = cg_alloc(max_nodes + 1);
    cg_depth_slots = cg_alloc(max_blocks + 2);
    cg_scc_indices = cg_alloc(max_funcs + 1);
    cg_scc_lowlink = cg_alloc(max_funcs + 1);
    cg_scc_on_stack = cg_alloc_bool(max_funcs + 1);
    cg_scc_of = cg_alloc(max_funcs + 1);
    cg_scc_node_stack = cg_alloc(max_funcs + 1);
    cg_scc_frame_slots = cg_alloc(max_funcs + 1);
    cg_scc_frame_nexts = cg_alloc(max_funcs + 1);
    cg_scc_order_scratch = cg_alloc(max_funcs + 1);
    cg_scc_order = cg_alloc(max_funcs + 1);

    /* A round rebuilds every table for one program; the programs rotate and
     * the fold's starting slot advances by one, so no two rounds fold the same
     * sequence into the accumulator. */
    while (round < rounds) {
        int64_t base = cg_program_base[program];
        int64_t count = cg_program_funcs[program];
        if (start >= count) {
            start = 0;
        }
        acc = cg_mix(acc, round);
        cg_function_index_build(base, count);
        cg_callgraph_build(base, count);
        cg_census_build(base, count);
        cg_scc_compute(count);
        acc = cg_program_fold(base, count, start, acc);
        acc = cg_mix(acc, (int64_t)cg_self_check(program));
        start += 1;
        program += 1;
        if (program >= programs) {
            program = 0;
        }
        round += 1;
    }
    return (int64_t)acc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)cg_bench(path, rounds));
    return 0;
}
