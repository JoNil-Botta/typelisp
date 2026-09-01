/* benchmarks/ssa_construct/baseline.c - clang C baseline for ssa_construct.
 *
 * Equivalent to benchmarks/ssa_construct/bench.tl: the TypeLisp optimizer's
 * `ssa` pass - phi placement at iterated dominance frontiers plus the
 * dominator-tree renaming walk - run over the real non-SSA functions the
 * compiler produced while compiling itself (see README.md for the corpus).
 *
 * Mirrored compiler functions, all in src/compiler_optimize.tl:
 *   opt-ssa-construct-function-from-context-and-representations-result
 *                                -- context, single-def gate, facts, the four
 *                                   early-outs, then construction
 *   opt-verify-single-defs?      -- the gate, and the post-construction check
 *   opt-ssa-facts-from-function-with-representations
 *                                -- definition counts in an open-addressed i64
 *                                   map, the `bad` set, the dense var -> type
 *                                   table and its insertion-order sidecar
 *   opt-ssa-candidate? / -any-candidate? /
 *   opt-ssa-blocks-have-candidate-phi-dst? /
 *   opt-ssa-context-within-budget? / opt-ssa-entry-has-preds?
 *   opt-ssa-def-blocks-from-function / opt-ssa-var-blocks-add
 *   opt-ssa-insert-phis / -types / -for-var / -worklist /
 *   opt-ssa-phi-add-frontier / opt-ssa-phi-add-site
 *   opt-cfg-dominance-frontier-with-context / -blocks / -block?
 *   opt-ssa-env-* (register, bind, lookup, checkpoint, rollback, snapshot,
 *                  snapshot-lookup, bind-phis, from-params)
 *   opt-ssa-rename-function-blocks / -tree / -tree-work / -instr-seq-from /
 *   opt-ssa-rename-dst / opt-ssa-rewrite-value / opt-ssa-rename-missing-blocks
 *   opt-ssa-materialize-blocks / opt-ssa-push-phis-for-label! /
 *   opt-ssa-phi-inputs / opt-ssa-rewrite-preexisting-phi-inputs
 *   opt-ssa-block-out-lookup / opt-ssa-rename-blocks-lookup-index
 *   opt-cfg-index-build / opt-cfg-dominators-with / opt-dom-build-euler! /
 *   opt-dom-info-dominates-id?
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
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define SSA_HASH_BASIS 1469598103934665603ULL
#define SSA_HASH_PRIME 1099511628211ULL
/* stdlib/hashmap.tl's i64 key hash. */
#define SSA_MAP_HASH_MUL 6364136223846793005ULL

static int64_t *ssa_tokens;
static int64_t *ssa_offsets;

static int64_t *ssa_succ_off;
static int64_t *ssa_succ_edge;
static int64_t *ssa_pred_off;
static int64_t *ssa_pred_edge;
static int64_t *ssa_pred_fill;
static int64_t *ssa_blk_base;
static int64_t *ssa_blk_count;

static int64_t *ssa_reachable;
static int64_t *ssa_postorder;
static int64_t *ssa_rpo;
static int64_t *ssa_rpo_num;
static int64_t *ssa_idom;
static int64_t *ssa_tin;
static int64_t *ssa_tout;
static int64_t *ssa_child_off;
static int64_t *ssa_child_edge;
static int64_t *ssa_child_fill;
static int64_t *ssa_stack_node;
static int64_t *ssa_stack_edge;

static int64_t *ssa_map_keys;
static int64_t *ssa_map_vals;
static int64_t *ssa_map_state;
static int64_t ssa_map_meta[8];
static int64_t *ssa_map_scratch_key;
static int64_t *ssa_map_scratch_val;
static int64_t *ssa_map_scratch_state;
static int64_t *ssa_ty;
static int64_t *ssa_ty_order;

static int64_t *ssa_vb_by_var;
static int64_t *ssa_vb_len;
static int64_t *ssa_vb_items;
static int64_t *ssa_vb_members;

static int64_t *ssa_site_var;
static int64_t *ssa_site_label;
static int64_t *ssa_site_ty;
static int64_t *ssa_site_phivar;
static int64_t *ssa_work_members;
static int64_t *ssa_site_members;
static int64_t *ssa_worklist;
static int64_t *ssa_df_set;

static int64_t *ssa_env_by_var;
static int64_t *ssa_env_current;
static int64_t *ssa_env_present;
static int64_t *ssa_chg_slot;
static int64_t *ssa_chg_val;
static int64_t *ssa_chg_present;

static int64_t *ssa_w_id;
static int64_t *ssa_w_exit;
static int64_t *ssa_w_chk;
static int64_t *ssa_child_head;
static int64_t *ssa_child_link;

static int64_t *ssa_rb_label;
static int64_t *ssa_rb_base;
static int64_t *ssa_rb_len;
static int64_t *ssa_rn;
static int64_t *ssa_out_label;
static int64_t *ssa_out_entry;
static int64_t *ssa_out_cur;
static int64_t *ssa_out_pres;

static int64_t *ssa_mt;
static int64_t *ssa_mt_base;
static int64_t *ssa_mt_len;
static int64_t *ssa_def_blk;
static int64_t *ssa_def_pos;
static int64_t *ssa_def_seen;

static int64_t ssa_frame;
static int64_t ssa_nparams;
static int64_t ssa_nblocks;
static int64_t ssa_ninstrs;
static int64_t ssa_exp_cands;
static int64_t ssa_exp_phis;
static int64_t ssa_exp_verify;
static int64_t ssa_verify_ok;
static int64_t ssa_param_base;
static int64_t ssa_reach_count;
static int64_t ssa_map_stride;
static int64_t ssa_ty_count;
static int64_t ssa_vb_count;
static int64_t ssa_site_count;
static int64_t ssa_site_cap;
static int64_t ssa_phi_next;
static int64_t ssa_env_count;
static int64_t ssa_chg_count;
static int64_t ssa_rb_count;
static int64_t ssa_rn_len;
static int64_t ssa_out_count;
static int64_t ssa_out_stride;
static int64_t ssa_mt_fill;
static int64_t ssa_next_var;
static int64_t ssa_cand_count;
static int64_t ssa_work_count;

static uint64_t ssa_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * SSA_HASH_PRIME;
}

static int64_t *ssa_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static char *ssa_read_file(const char *path, int64_t *length) {
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

static int64_t ssa_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int ssa_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t ssa_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = ssa_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && ssa_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (ssa_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (ssa_digit(ssa_byte_at(text, n, i))) {
                value = value * 10 + (ssa_byte_at(text, n, i) - 48);
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

/* --- open-addressed i64 -> i64 map (stdlib/hashmap.tl's i64 family) -------- */
static void ssa_map_reset(int64_t map_id, int64_t capacity) {
    int64_t base = map_id * ssa_map_stride;
    int64_t i = 0;
    while (i < capacity) {
        ssa_map_state[base + i] = 0;
        i += 1;
    }
    ssa_map_meta[map_id * 4] = capacity;
    ssa_map_meta[map_id * 4 + 1] = 0;
    ssa_map_meta[map_id * 4 + 2] = capacity - (capacity >> 2);
}

static int64_t ssa_map_find(int64_t map_id, int64_t key) {
    int64_t base = map_id * ssa_map_stride;
    int64_t capacity = ssa_map_meta[map_id * 4];
    int64_t mask = capacity - 1;
    int64_t cursor = (int64_t)((uint64_t)key * SSA_MAP_HASH_MUL) & mask;
    int64_t walked = 0;
    while (walked < capacity) {
        int64_t slot = base + cursor;
        if (ssa_map_state[slot] == 0) {
            return -1;
        }
        if (ssa_map_keys[slot] == key) {
            return slot;
        }
        cursor = (cursor + 1) & mask;
        walked += 1;
    }
    return -1;
}

static int64_t ssa_map_get(int64_t map_id, int64_t key, int64_t fallback) {
    int64_t slot = ssa_map_find(map_id, key);
    return slot < 0 ? fallback : ssa_map_vals[slot];
}

static int ssa_map_contains(int64_t map_id, int64_t key) {
    return ssa_map_find(map_id, key) >= 0;
}

static void ssa_map_grow(int64_t map_id) {
    int64_t base = map_id * ssa_map_stride;
    int64_t old_capacity = ssa_map_meta[map_id * 4];
    int64_t capacity = old_capacity * 2;
    int64_t mask = capacity - 1;
    int64_t scan = 0;
    while (scan < old_capacity) {
        ssa_map_scratch_key[scan] = ssa_map_keys[base + scan];
        ssa_map_scratch_val[scan] = ssa_map_vals[base + scan];
        ssa_map_scratch_state[scan] = ssa_map_state[base + scan];
        scan += 1;
    }
    scan = 0;
    while (scan < capacity) {
        ssa_map_state[base + scan] = 0;
        scan += 1;
    }
    scan = 0;
    while (scan < old_capacity) {
        if (ssa_map_scratch_state[scan] == 1) {
            int64_t key = ssa_map_scratch_key[scan];
            int64_t cursor = (int64_t)((uint64_t)key * SSA_MAP_HASH_MUL) & mask;
            while (ssa_map_state[base + cursor] == 1) {
                cursor = (cursor + 1) & mask;
            }
            ssa_map_state[base + cursor] = 1;
            ssa_map_keys[base + cursor] = key;
            ssa_map_vals[base + cursor] = ssa_map_scratch_val[scan];
        }
        scan += 1;
    }
    ssa_map_meta[map_id * 4] = capacity;
    ssa_map_meta[map_id * 4 + 2] = capacity - (capacity >> 2);
}

static void ssa_map_insert(int64_t map_id, int64_t key, int64_t value) {
    int64_t slot = ssa_map_find(map_id, key);
    if (slot >= 0) {
        ssa_map_vals[slot] = value;
    } else {
        int64_t base;
        int64_t mask;
        int64_t cursor;
        if (ssa_map_meta[map_id * 4 + 1] >= ssa_map_meta[map_id * 4 + 2]) {
            ssa_map_grow(map_id);
        }
        base = map_id * ssa_map_stride;
        mask = ssa_map_meta[map_id * 4] - 1;
        cursor = (int64_t)((uint64_t)key * SSA_MAP_HASH_MUL) & mask;
        while (ssa_map_state[base + cursor] == 1) {
            cursor = (cursor + 1) & mask;
        }
        ssa_map_state[base + cursor] = 1;
        ssa_map_keys[base + cursor] = key;
        ssa_map_vals[base + cursor] = value;
        ssa_map_meta[map_id * 4 + 1] += 1;
    }
}

/* --- corpus decoding ------------------------------------------------------ */
static int64_t ssa_instr_next(const int64_t *items, int64_t pos) {
    int64_t kind = items[pos];
    if (kind == 5) {
        return pos + 4 + 2 * items[pos + 3];
    }
    {
        int64_t uses = items[pos + 1];
        return pos + 2 + uses + (kind == 0 ? 0 : 1) + (kind == 1 ? 1 : 0);
    }
}

static int64_t ssa_instr_dst(const int64_t *items, int64_t pos) {
    int64_t kind = items[pos];
    if (kind == 0) {
        return -1;
    }
    if (kind == 5) {
        return items[pos + 1];
    }
    return items[pos + 2 + items[pos + 1]];
}

/* opt-cfg-index-build for one corpus record. */
static void ssa_load_function(int64_t offset) {
    int64_t cursor = offset;
    int64_t block = 0;
    int64_t edge = 0;
    int64_t total = 0;
    ssa_frame = ssa_tokens[cursor];
    ssa_nparams = ssa_tokens[cursor + 1];
    ssa_nblocks = ssa_tokens[cursor + 2];
    ssa_ninstrs = ssa_tokens[cursor + 3];
    ssa_exp_cands = ssa_tokens[cursor + 4];
    ssa_exp_phis = ssa_tokens[cursor + 5];
    ssa_exp_verify = ssa_tokens[cursor + 6];
    ssa_param_base = cursor + 7;
    cursor = cursor + 7 + 2 * ssa_nparams;
    while (block < ssa_nblocks) {
        int64_t succs = ssa_tokens[cursor];
        int64_t k = 0;
        int64_t count;
        ssa_succ_off[block] = edge;
        while (k < succs) {
            ssa_succ_edge[edge] = ssa_tokens[cursor + 1 + k];
            edge += 1;
            k += 1;
        }
        cursor = cursor + 1 + succs;
        count = ssa_tokens[cursor];
        cursor += 1;
        ssa_blk_base[block] = cursor;
        ssa_blk_count[block] = count;
        k = 0;
        while (k < count) {
            cursor = ssa_instr_next(ssa_tokens, cursor);
            k += 1;
        }
        block += 1;
    }
    ssa_succ_off[ssa_nblocks] = edge;
    block = 0;
    while (block < ssa_nblocks) {
        ssa_pred_fill[block] = 0;
        block += 1;
    }
    block = 0;
    while (block < edge) {
        ssa_pred_fill[ssa_succ_edge[block]] += 1;
        block += 1;
    }
    block = 0;
    while (block < ssa_nblocks) {
        ssa_pred_off[block] = total;
        total += ssa_pred_fill[block];
        ssa_pred_fill[block] = ssa_pred_off[block];
        block += 1;
    }
    ssa_pred_off[ssa_nblocks] = total;
    block = 0;
    while (block < ssa_nblocks) {
        int64_t k = ssa_succ_off[block];
        int64_t end = ssa_succ_off[block + 1];
        while (k < end) {
            int64_t dst = ssa_succ_edge[k];
            ssa_pred_edge[ssa_pred_fill[dst]] = block;
            ssa_pred_fill[dst] += 1;
            k += 1;
        }
        block += 1;
    }
}

/* --- opt-cfg-context-build ------------------------------------------------ */
static void ssa_dfs_postorder(void) {
    int64_t count = ssa_nblocks;
    int64_t i = 0;
    int64_t sp = 0;
    int64_t post = 0;
    while (i < count) {
        ssa_reachable[i] = 0;
        ssa_postorder[i] = -1;
        ssa_rpo[i] = -1;
        ssa_rpo_num[i] = -1;
        i += 1;
    }
    if (count > 0) {
        ssa_reachable[0] = 1;
        ssa_stack_node[0] = 0;
        ssa_stack_edge[0] = ssa_succ_off[0];
        sp = 0;
        while (sp >= 0) {
            int64_t node = ssa_stack_node[sp];
            int64_t cursor = ssa_stack_edge[sp];
            if (cursor < ssa_succ_off[node + 1]) {
                int64_t next = ssa_succ_edge[cursor];
                ssa_stack_edge[sp] = cursor + 1;
                if (ssa_reachable[next] == 0) {
                    ssa_reachable[next] = 1;
                    sp += 1;
                    ssa_stack_node[sp] = next;
                    ssa_stack_edge[sp] = ssa_succ_off[next];
                }
            } else {
                ssa_postorder[post] = node;
                post += 1;
                sp -= 1;
            }
        }
    }
    ssa_reach_count = post;
    i = 0;
    while (i < post) {
        ssa_rpo[i] = ssa_postorder[post - 1 - i];
        i += 1;
    }
    i = 0;
    while (i < post) {
        ssa_rpo_num[ssa_rpo[i]] = i;
        i += 1;
    }
}

static int ssa_idom_iterate(void) {
    int64_t slot = 1;
    int changed = 0;
    while (slot < ssa_reach_count) {
        int64_t id = ssa_rpo[slot];
        int64_t edge = ssa_pred_off[id];
        int64_t end = ssa_pred_off[id + 1];
        int64_t candidate = -1;
        while (edge < end) {
            int64_t pred = ssa_pred_edge[edge];
            if (ssa_reachable[pred] == 1 && ssa_idom[pred] >= 0) {
                if (candidate < 0) {
                    candidate = pred;
                } else {
                    int64_t a = pred;
                    int64_t b = candidate;
                    while (a != b) {
                        while (ssa_rpo_num[a] > ssa_rpo_num[b]) {
                            a = ssa_idom[a];
                        }
                        while (ssa_rpo_num[b] > ssa_rpo_num[a]) {
                            b = ssa_idom[b];
                        }
                    }
                    candidate = a;
                }
            }
            edge += 1;
        }
        if (id != 0 && candidate >= 0 && ssa_idom[id] != candidate) {
            ssa_idom[id] = candidate;
            changed = 1;
        }
        slot += 1;
    }
    return changed;
}

static void ssa_build_euler(void) {
    int64_t count = ssa_nblocks;
    int64_t i = 0;
    int64_t total = 0;
    int64_t sp = 0;
    int64_t time = 0;
    while (i < count) {
        ssa_tin[i] = -1;
        ssa_tout[i] = -1;
        ssa_child_fill[i] = 0;
        i += 1;
    }
    i = 0;
    while (i < count) {
        int64_t parent = ssa_idom[i];
        if (ssa_reachable[i] == 1 && parent >= 0 && parent != i) {
            ssa_child_fill[parent] += 1;
        }
        i += 1;
    }
    i = 0;
    while (i < count) {
        ssa_child_off[i] = total;
        total += ssa_child_fill[i];
        ssa_child_fill[i] = ssa_child_off[i];
        i += 1;
    }
    ssa_child_off[count] = total;
    i = 0;
    while (i < count) {
        int64_t parent = ssa_idom[i];
        if (ssa_reachable[i] == 1 && parent >= 0 && parent != i) {
            ssa_child_edge[ssa_child_fill[parent]] = i;
            ssa_child_fill[parent] += 1;
        }
        i += 1;
    }
    if (count > 0 && ssa_reachable[0] == 1) {
        ssa_stack_node[0] = 0;
        ssa_stack_edge[0] = ssa_child_off[0];
        ssa_tin[0] = 0;
        time = 1;
        sp = 0;
        while (sp >= 0) {
            int64_t node = ssa_stack_node[sp];
            int64_t cursor = ssa_stack_edge[sp];
            if (cursor < ssa_child_off[node + 1]) {
                int64_t child = ssa_child_edge[cursor];
                ssa_stack_edge[sp] = cursor + 1;
                ssa_tin[child] = time;
                time += 1;
                sp += 1;
                ssa_stack_node[sp] = child;
                ssa_stack_edge[sp] = ssa_child_off[child];
            } else {
                ssa_tout[node] = time;
                sp -= 1;
            }
        }
    }
}

/* opt-dom-info-dominates-id? */
static int ssa_dominates(int64_t dominator, int64_t label) {
    if (ssa_reachable[dominator] == 1 && ssa_reachable[label] == 1) {
        return ssa_tin[dominator] >= 0 && ssa_tin[label] >= 0 &&
               ssa_tin[dominator] <= ssa_tin[label] &&
               ssa_tout[label] <= ssa_tout[dominator];
    }
    return 0;
}

static void ssa_build_context(void) {
    int64_t i = 0;
    int64_t remaining = 0;
    ssa_dfs_postorder();
    while (i < ssa_nblocks) {
        ssa_idom[i] = -1;
        i += 1;
    }
    if (ssa_nblocks > 0 && ssa_reachable[0] == 1) {
        ssa_idom[0] = 0;
        remaining = ssa_nblocks + 1;
        while (remaining > 0 && ssa_idom_iterate()) {
            remaining -= 1;
        }
    }
    ssa_build_euler();
}

static int ssa_entry_has_preds(void) {
    return ssa_pred_off[1] - ssa_pred_off[0] > 0;
}

/* --- opt-verify-single-defs? over the input function ---------------------- */
static int ssa_input_single_defs(void) {
    int64_t i = 0;
    int64_t block = 0;
    while (i < ssa_frame) {
        ssa_def_seen[i] = 0;
        i += 1;
    }
    i = 0;
    while (i < ssa_nparams) {
        int64_t var = ssa_tokens[ssa_param_base + 2 * i];
        if (var < 0 || var >= ssa_frame || ssa_def_seen[var] == 1) {
            return 0;
        }
        ssa_def_seen[var] = 1;
        i += 1;
    }
    while (block < ssa_nblocks) {
        int64_t pos = ssa_blk_base[block];
        int64_t k = 0;
        int64_t count = ssa_blk_count[block];
        while (k < count) {
            int64_t dst = ssa_instr_dst(ssa_tokens, pos);
            if (dst >= 0) {
                if (dst >= ssa_frame || ssa_def_seen[dst] == 1) {
                    return 0;
                }
                ssa_def_seen[dst] = 1;
            }
            pos = ssa_instr_next(ssa_tokens, pos);
            k += 1;
        }
        block += 1;
    }
    return 1;
}

/* --- opt-ssa-facts-from-function-with-representations --------------------- */
static void ssa_facts_add_def_ty(int64_t var, int64_t ty) {
    ssa_map_insert(0, var, ssa_map_get(0, var, 0) + 1);
    if (ty < 0) {
        ssa_map_insert(1, var, 1);
    } else {
        int64_t old = ssa_ty[var];
        if (old == 0) {
            ssa_ty[var] = ty;
            ssa_ty_order[ssa_ty_count] = var;
            ssa_ty_count += 1;
        } else if (old != ty) {
            ssa_map_insert(1, var, 1);
        }
    }
}

static void ssa_facts_add_def_bad(int64_t var) {
    ssa_map_insert(0, var, ssa_map_get(0, var, 0) + 1);
    ssa_map_insert(1, var, 1);
}

static void ssa_build_facts(void) {
    int64_t i = 0;
    int64_t block = 0;
    ssa_map_reset(0, 64);
    ssa_map_reset(1, 64);
    while (i < ssa_frame) {
        ssa_ty[i] = 0;
        i += 1;
    }
    ssa_ty_count = 0;
    i = 0;
    while (i < ssa_nparams) {
        ssa_facts_add_def_ty(ssa_tokens[ssa_param_base + 2 * i],
                             ssa_tokens[ssa_param_base + 2 * i + 1]);
        i += 1;
    }
    while (block < ssa_nblocks) {
        int64_t pos = ssa_blk_base[block];
        int64_t k = 0;
        int64_t count = ssa_blk_count[block];
        while (k < count) {
            int64_t kind = ssa_tokens[pos];
            int64_t uses;
            if (kind == 1) {
                uses = ssa_tokens[pos + 1];
                ssa_facts_add_def_ty(ssa_tokens[pos + 2 + uses],
                                     ssa_tokens[pos + 3 + uses]);
            } else if (kind == 5) {
                ssa_facts_add_def_ty(ssa_tokens[pos + 1], ssa_tokens[pos + 2]);
            } else if (kind == 2) {
                ssa_facts_add_def_bad(
                    ssa_tokens[pos + 2 + ssa_tokens[pos + 1]]);
            } else if (kind == 3) {
                uses = ssa_tokens[pos + 1];
                ssa_facts_add_def_bad(ssa_tokens[pos + 2 + uses]);
                if (uses > 0) {
                    ssa_map_insert(1, ssa_tokens[pos + 2], 1);
                }
            }
            pos = ssa_instr_next(ssa_tokens, pos);
            k += 1;
        }
        block += 1;
    }
}

/* opt-ssa-candidate? */
static int ssa_candidate(int64_t var) {
    return ssa_map_get(0, var, 0) > 1 && !ssa_map_contains(1, var) &&
           ssa_ty[var] != 0;
}

static int64_t ssa_count_candidates(void) {
    int64_t index = 0;
    int64_t count = 0;
    while (index < ssa_ty_count) {
        if (ssa_candidate(ssa_ty_order[ssa_ty_count - index - 1])) {
            count += 1;
        }
        index += 1;
    }
    return count;
}

/* opt-ssa-blocks-have-candidate-phi-dst? */
static int ssa_candidate_phi_dst(void) {
    int64_t block = 0;
    while (block < ssa_nblocks) {
        int64_t pos = ssa_blk_base[block];
        int64_t k = 0;
        int64_t count = ssa_blk_count[block];
        while (k < count) {
            if (ssa_tokens[pos] == 5 && ssa_candidate(ssa_tokens[pos + 1])) {
                return 1;
            }
            pos = ssa_instr_next(ssa_tokens, pos);
            k += 1;
        }
        block += 1;
    }
    return 0;
}

/* --- opt-ssa-def-blocks-from-function ------------------------------------- */
static void ssa_var_blocks_add(int64_t var, int64_t label) {
    int64_t slot = ssa_vb_by_var[var];
    int64_t entry;
    int64_t base;
    if (slot > 0) {
        entry = slot - 1;
    } else {
        int64_t i = 0;
        entry = ssa_vb_count;
        ssa_vb_count += 1;
        base = entry * ssa_nblocks;
        /* `opt-ssa-label-members-new` allocates a zeroed block-count array the
         * first time a var gets a definition site. */
        while (i < ssa_nblocks) {
            ssa_vb_members[base + i] = 0;
            i += 1;
        }
        ssa_vb_len[entry] = 0;
        ssa_vb_by_var[var] = entry + 1;
    }
    base = entry * ssa_nblocks;
    if (ssa_vb_members[base + label] == 0) {
        ssa_vb_members[base + label] = 1;
        ssa_vb_items[base + ssa_vb_len[entry]] = label;
        ssa_vb_len[entry] += 1;
    }
}

static void ssa_def_blocks(void) {
    int64_t i = 0;
    int64_t block = 0;
    while (i < ssa_frame) {
        ssa_vb_by_var[i] = 0;
        i += 1;
    }
    ssa_vb_count = 0;
    i = 0;
    while (i < ssa_nparams) {
        int64_t var = ssa_tokens[ssa_param_base + 2 * i];
        if (ssa_candidate(var)) {
            ssa_var_blocks_add(var, 0);
        }
        i += 1;
    }
    while (block < ssa_nblocks) {
        int64_t pos = ssa_blk_base[block];
        int64_t k = 0;
        int64_t count = ssa_blk_count[block];
        while (k < count) {
            int64_t dst = ssa_instr_dst(ssa_tokens, pos);
            if (dst >= 0 && ssa_candidate(dst)) {
                ssa_var_blocks_add(dst, block);
            }
            pos = ssa_instr_next(ssa_tokens, pos);
            k += 1;
        }
        block += 1;
    }
}

/* --- opt-cfg-dominance-frontier-with-context ------------------------------
 *
 * A full block scan per query, no cache. `opt-label-add` re-scans the growing
 * set. */
static int64_t ssa_dominance_frontier(int64_t label) {
    int64_t block = 0;
    int64_t len = 0;
    while (block < ssa_nblocks) {
        if (ssa_reachable[block] == 1) {
            int64_t edge = ssa_pred_off[block];
            int64_t end = ssa_pred_off[block + 1];
            int found = 0;
            int64_t i = 0;
            while (edge < end && !found) {
                int64_t pred = ssa_pred_edge[edge];
                if (ssa_reachable[pred] == 1 && ssa_dominates(label, pred)) {
                    found = 1;
                }
                edge += 1;
            }
            if (found && !(label != block && ssa_dominates(label, block))) {
                int seen = 0;
                while (i < len) {
                    if (ssa_df_set[i] == block) {
                        seen = 1;
                    }
                    i += 1;
                }
                if (!seen) {
                    ssa_df_set[len] = block;
                    len += 1;
                }
            }
        }
        block += 1;
    }
    return len;
}

/* --- opt-ssa-insert-phis -------------------------------------------------- */
static void ssa_phi_add_site(int64_t var, int64_t ty, int64_t label) {
    if (ssa_site_members[label] == 0 && ssa_site_count < ssa_site_cap) {
        ssa_site_members[label] = 1;
        ssa_site_var[ssa_site_count] = var;
        ssa_site_label[ssa_site_count] = label;
        ssa_site_ty[ssa_site_count] = ty;
        ssa_site_phivar[ssa_site_count] = ssa_phi_next;
        ssa_site_count += 1;
        ssa_phi_next += 1;
        if (ssa_work_members[label] == 0) {
            ssa_work_members[label] = 1;
            ssa_worklist[ssa_work_count] = label;
            ssa_work_count += 1;
        }
    }
}

static void ssa_insert_phis_for_var(int64_t var, int64_t ty) {
    int64_t i = 0;
    int64_t slot = ssa_vb_by_var[var];
    while (i < ssa_nblocks) {
        ssa_work_members[i] = 0;
        ssa_site_members[i] = 0;
        i += 1;
    }
    ssa_work_count = 0;
    if (slot > 0) {
        int64_t base = (slot - 1) * ssa_nblocks;
        int64_t len = ssa_vb_len[slot - 1];
        i = 0;
        while (i < len) {
            ssa_worklist[i] = ssa_vb_items[base + i];
            ssa_work_members[ssa_vb_items[base + i]] = 1;
            i += 1;
        }
        ssa_work_count = len;
    }
    while (ssa_work_count > 0) {
        int64_t label = ssa_worklist[ssa_work_count - 1];
        int64_t len;
        int64_t k = 0;
        ssa_work_count -= 1;
        len = ssa_dominance_frontier(label);
        while (k < len) {
            ssa_phi_add_site(var, ty, ssa_df_set[k]);
            k += 1;
        }
    }
}

static void ssa_insert_phis(void) {
    int64_t index = 0;
    ssa_site_count = 0;
    ssa_phi_next = ssa_frame;
    ssa_def_blocks();
    while (index < ssa_ty_count) {
        int64_t var = ssa_ty_order[ssa_ty_count - index - 1];
        if (ssa_candidate(var)) {
            ssa_insert_phis_for_var(var, ssa_ty[var]);
        }
        index += 1;
    }
}

/* --- opt-ssa-rename-* ----------------------------------------------------- */
static int64_t ssa_env_lookup(int64_t var) {
    int64_t slot;
    if (var < 0 || var >= ssa_phi_next) {
        return -1;
    }
    slot = ssa_env_by_var[var] - 1;
    if (slot < 0 || slot >= ssa_env_count || ssa_env_present[slot] == 0) {
        return -1;
    }
    return ssa_env_current[slot];
}

static void ssa_env_bind(int64_t original, int64_t current) {
    int64_t slot = ssa_env_by_var[original] - 1;
    ssa_chg_slot[ssa_chg_count] = slot;
    ssa_chg_val[ssa_chg_count] = ssa_env_current[slot];
    ssa_chg_present[ssa_chg_count] = ssa_env_present[slot];
    ssa_env_current[slot] = current;
    ssa_env_present[slot] = 1;
    ssa_chg_count += 1;
}

static void ssa_env_rollback(int64_t checkpoint) {
    while (ssa_chg_count > checkpoint) {
        int64_t change = ssa_chg_count - 1;
        int64_t slot = ssa_chg_slot[change];
        ssa_env_current[slot] = ssa_chg_val[change];
        ssa_env_present[slot] = ssa_chg_present[change];
        ssa_chg_count = change;
    }
}

/* opt-ssa-env-bind-phis: a full newest-first scan of the phi sites per block. */
static void ssa_env_bind_phis(int64_t label) {
    int64_t index = 0;
    while (index < ssa_site_count) {
        int64_t site = ssa_site_count - index - 1;
        if (ssa_site_label[site] == label) {
            ssa_env_bind(ssa_site_var[site], ssa_site_phivar[site]);
        }
        index += 1;
    }
}

/* opt-ssa-rename-instr-seq-from + opt-ssa-rename-dst + opt-ssa-rewrite-value.
 * A Phi passes through untouched; its inputs are edge uses resolved later. */
static void ssa_rename_block(int64_t block) {
    int64_t pos = ssa_blk_base[block];
    int64_t k = 0;
    int64_t count = ssa_blk_count[block];
    while (k < count) {
        int64_t kind = ssa_tokens[pos];
        int64_t next = ssa_instr_next(ssa_tokens, pos);
        int64_t i = 0;
        if (kind == 5) {
            while (pos + i < next) {
                ssa_rn[ssa_rn_len + i] = ssa_tokens[pos + i];
                i += 1;
            }
            ssa_rn_len += i;
        } else {
            int64_t uses = ssa_tokens[pos + 1];
            ssa_rn[ssa_rn_len] = kind;
            ssa_rn[ssa_rn_len + 1] = uses;
            i = 0;
            while (i < uses) {
                int64_t var = ssa_tokens[pos + 2 + i];
                int64_t current = ssa_env_lookup(var);
                ssa_rn[ssa_rn_len + 2 + i] = current < 0 ? var : current;
                i += 1;
            }
            if (kind != 0) {
                int64_t dst = ssa_tokens[pos + 2 + uses];
                if (ssa_candidate(dst)) {
                    ssa_rn[ssa_rn_len + 2 + uses] = ssa_next_var;
                    ssa_env_bind(dst, ssa_next_var);
                    ssa_next_var += 1;
                } else {
                    ssa_rn[ssa_rn_len + 2 + uses] = dst;
                }
                if (kind == 1) {
                    ssa_rn[ssa_rn_len + 3 + uses] = ssa_tokens[pos + 3 + uses];
                }
            }
            ssa_rn_len += next - pos;
        }
        pos = next;
        k += 1;
    }
}

static void ssa_add_rename_block(int64_t block, int64_t base) {
    int64_t i = 0;
    int64_t dest = ssa_out_count * ssa_out_stride;
    ssa_rb_label[ssa_rb_count] = block;
    ssa_rb_base[ssa_rb_count] = base;
    ssa_rb_len[ssa_rb_count] = ssa_rn_len - base;
    ssa_rb_count += 1;
    /* opt-ssa-env-snapshot clones the compact current/present prefixes. */
    while (i < ssa_env_count) {
        ssa_out_cur[dest + i] = ssa_env_current[i];
        ssa_out_pres[dest + i] = ssa_env_present[i];
        i += 1;
    }
    ssa_out_label[ssa_out_count] = block;
    ssa_out_entry[ssa_out_count] = ssa_env_count;
    ssa_out_count += 1;
}

/* opt-ssa-block-out-lookup: linear, newest first. */
static int64_t ssa_out_lookup(int64_t label) {
    int64_t index = 0;
    while (index < ssa_out_count) {
        int64_t entry = ssa_out_count - index - 1;
        if (ssa_out_label[entry] == label) {
            return entry;
        }
        index += 1;
    }
    return -1;
}

/* opt-ssa-rename-blocks-lookup-index: linear, newest first. */
static int64_t ssa_rb_lookup(int64_t label) {
    int64_t index = 0;
    while (index < ssa_rb_count) {
        int64_t entry = ssa_rb_count - index - 1;
        if (ssa_rb_label[entry] == label) {
            return entry;
        }
        index += 1;
    }
    return -1;
}

/* opt-ssa-env-snapshot-lookup */
static int64_t ssa_snapshot_lookup(int64_t entry, int64_t var) {
    int64_t slot;
    if (entry < 0 || var < 0 || var >= ssa_phi_next) {
        return -1;
    }
    slot = ssa_env_by_var[var] - 1;
    if (slot < 0 || slot >= ssa_out_entry[entry] ||
        ssa_out_pres[entry * ssa_out_stride + slot] == 0) {
        return -1;
    }
    return ssa_out_cur[entry * ssa_out_stride + slot];
}

static void ssa_rename_tree(void) {
    int64_t count = ssa_nblocks;
    int64_t i = 0;
    int64_t work = 0;
    while (i < count) {
        ssa_child_head[i] = 0;
        ssa_child_link[i] = 0;
        i += 1;
    }
    i = 0;
    while (i < count) {
        if (ssa_idom[i] != i && ssa_reachable[i] == 1) {
            int64_t parent = ssa_idom[i];
            if (parent >= 0 && parent < count) {
                ssa_child_link[i] = ssa_child_head[parent];
                ssa_child_head[parent] = i + 1;
            }
        }
        i += 1;
    }
    ssa_w_id[0] = 0;
    ssa_w_exit[0] = 0;
    ssa_w_chk[0] = 0;
    work = 1;
    while (work > 0) {
        int64_t slot = work - 1;
        int64_t id = ssa_w_id[slot];
        int64_t checkpoint = ssa_w_chk[slot];
        if (ssa_w_exit[slot] == 1) {
            ssa_env_rollback(checkpoint);
            work = slot;
        } else {
            int64_t block_checkpoint = ssa_chg_count;
            int64_t base = ssa_rn_len;
            int64_t link;
            ssa_env_bind_phis(id);
            ssa_rename_block(id);
            ssa_add_rename_block(id, base);
            ssa_w_id[slot] = id;
            ssa_w_exit[slot] = 1;
            ssa_w_chk[slot] = block_checkpoint;
            work = slot + 1;
            link = ssa_child_head[id];
            while (link > 0) {
                int64_t child = link - 1;
                ssa_w_id[work] = child;
                ssa_w_exit[work] = 0;
                ssa_w_chk[work] = 0;
                work += 1;
                link = ssa_child_link[child];
            }
        }
    }
}

static void ssa_rename_missing_blocks(void) {
    int64_t block = 0;
    while (block < ssa_nblocks) {
        if (ssa_rb_lookup(block) < 0) {
            int64_t checkpoint = ssa_chg_count;
            int64_t base = ssa_rn_len;
            ssa_env_bind_phis(block);
            ssa_rename_block(block);
            ssa_add_rename_block(block, base);
            ssa_env_rollback(checkpoint);
        }
        block += 1;
    }
}

static void ssa_rename(void) {
    int64_t index = 0;
    ssa_env_count = 0;
    ssa_chg_count = 0;
    while (index < ssa_phi_next) {
        ssa_env_by_var[index] = 0;
        index += 1;
    }
    index = 0;
    while (index < ssa_ty_count) {
        int64_t var = ssa_ty_order[ssa_ty_count - index - 1];
        if (ssa_candidate(var) && ssa_env_by_var[var] == 0) {
            ssa_env_by_var[var] = ssa_env_count + 1;
            ssa_env_current[ssa_env_count] = 0;
            ssa_env_present[ssa_env_count] = 0;
            ssa_env_count += 1;
        }
        index += 1;
    }
    index = 0;
    while (index < ssa_nparams) {
        int64_t var = ssa_tokens[ssa_param_base + 2 * index];
        if (ssa_candidate(var)) {
            ssa_env_bind(var, var);
        }
        index += 1;
    }
    ssa_rb_count = 0;
    ssa_out_count = 0;
    ssa_rn_len = 0;
    ssa_next_var = ssa_phi_next;
    ssa_rename_tree();
    ssa_rename_missing_blocks();
}

/* --- opt-ssa-materialize-blocks ------------------------------------------- */
static void ssa_materialize(void) {
    int64_t block = 0;
    ssa_mt_fill = 0;
    while (block < ssa_nblocks) {
        int64_t index = 0;
        int64_t start = ssa_mt_fill;
        int64_t entry;
        /* opt-ssa-push-phis-for-label!: sites newest first, each operand
         * resolved in the OUT snapshot of its named predecessor. */
        while (index < ssa_site_count) {
            int64_t site = ssa_site_count - index - 1;
            if (ssa_site_label[site] == block) {
                int64_t edge = ssa_pred_off[block + 1] - 1;
                int64_t stop = ssa_pred_off[block];
                int64_t head = ssa_mt_fill;
                int64_t inputs = 0;
                ssa_mt[head] = 5;
                ssa_mt[head + 1] = ssa_site_phivar[site];
                ssa_mt[head + 2] = ssa_site_ty[site];
                ssa_mt_fill = head + 4;
                while (edge >= stop) {
                    int64_t pred = ssa_pred_edge[edge];
                    int64_t snapshot = ssa_out_lookup(pred);
                    ssa_mt[ssa_mt_fill] =
                        ssa_snapshot_lookup(snapshot, ssa_site_var[site]);
                    ssa_mt[ssa_mt_fill + 1] = pred;
                    ssa_mt_fill += 2;
                    inputs += 1;
                    edge -= 1;
                }
                ssa_mt[head + 3] = inputs;
            }
            index += 1;
        }
        /* opt-ssa-push-rewritten-preexisting-instrs! */
        entry = ssa_rb_lookup(block);
        if (entry >= 0) {
            int64_t pos = ssa_rb_base[entry];
            int64_t stop = ssa_rb_base[entry] + ssa_rb_len[entry];
            while (pos < stop) {
                int64_t next = ssa_instr_next(ssa_rn, pos);
                int64_t i = 0;
                while (pos + i < next) {
                    ssa_mt[ssa_mt_fill + i] = ssa_rn[pos + i];
                    i += 1;
                }
                if (ssa_rn[pos] == 5) {
                    int64_t inputs = ssa_rn[pos + 3];
                    int64_t k = 0;
                    while (k < inputs) {
                        int64_t value = ssa_rn[pos + 4 + 2 * k];
                        int64_t pred = ssa_rn[pos + 5 + 2 * k];
                        if (value >= 0 && ssa_candidate(value)) {
                            ssa_mt[ssa_mt_fill + 4 + 2 * k] =
                                ssa_snapshot_lookup(ssa_out_lookup(pred),
                                                    value);
                        }
                        k += 1;
                    }
                }
                ssa_mt_fill += next - pos;
                pos = next;
            }
        }
        ssa_mt_base[block] = start;
        ssa_mt_len[block] = ssa_mt_fill - start;
        block += 1;
    }
}

/* --- opt-ssa-construct-checked: single defs, then use dominance ----------- */
static int64_t ssa_verify_defs(void) {
    int64_t block = 0;
    int64_t i = 0;
    int64_t ok = 1;
    while (i < ssa_next_var) {
        ssa_def_seen[i] = 0;
        i += 1;
    }
    i = 0;
    while (i < ssa_nparams) {
        int64_t var = ssa_tokens[ssa_param_base + 2 * i];
        if (ssa_def_seen[var] == 1) {
            ok = 0;
        }
        ssa_def_seen[var] = 1;
        ssa_def_blk[var] = 0;
        ssa_def_pos[var] = 0;
        i += 1;
    }
    while (block < ssa_nblocks) {
        int64_t pos = ssa_mt_base[block];
        int64_t stop = ssa_mt_base[block] + ssa_mt_len[block];
        int64_t order = 1;
        while (pos < stop) {
            int64_t dst = ssa_instr_dst(ssa_mt, pos);
            if (dst >= 0) {
                if (ssa_def_seen[dst] == 1) {
                    ok = 0;
                }
                ssa_def_seen[dst] = 1;
                ssa_def_blk[dst] = block;
                ssa_def_pos[dst] = ssa_mt[pos] == 5 ? 0 : order;
            }
            order += 1;
            pos = ssa_instr_next(ssa_mt, pos);
        }
        block += 1;
    }
    return ok;
}

static int64_t ssa_verify_phi_uses(int64_t pos) {
    int64_t inputs = ssa_mt[pos + 3];
    int64_t k = 0;
    int64_t ok = 1;
    while (k < inputs) {
        int64_t value = ssa_mt[pos + 4 + 2 * k];
        int64_t pred = ssa_mt[pos + 5 + 2 * k];
        if (value >= 0 && ssa_reachable[pred] == 1) {
            if (ssa_def_seen[value] == 0 ||
                !ssa_dominates(ssa_def_blk[value], pred)) {
                ok = 0;
            }
        }
        k += 1;
    }
    return ok;
}

static int64_t ssa_verify_plain_uses(int64_t pos, int64_t block, int64_t order) {
    int64_t uses = ssa_mt[pos + 1];
    int64_t k = 0;
    int64_t ok = 1;
    while (k < uses) {
        int64_t value = ssa_mt[pos + 2 + k];
        if (ssa_def_seen[value] == 1) {
            int64_t home = ssa_def_blk[value];
            int good = home == block ? ssa_def_pos[value] < order
                                     : ssa_dominates(home, block);
            if (!good) {
                ok = 0;
            }
        }
        k += 1;
    }
    return ok;
}

static int64_t ssa_verify(void) {
    int64_t block = 0;
    int64_t ok = ssa_verify_defs();
    while (block < ssa_nblocks) {
        if (ssa_reachable[block] == 1) {
            int64_t pos = ssa_mt_base[block];
            int64_t stop = ssa_mt_base[block] + ssa_mt_len[block];
            int64_t order = 1;
            while (pos < stop) {
                int64_t next = ssa_instr_next(ssa_mt, pos);
                int64_t one = ssa_mt[pos] == 5
                                  ? ssa_verify_phi_uses(pos)
                                  : ssa_verify_plain_uses(pos, block, order);
                if (one == 0) {
                    ok = 0;
                }
                order += 1;
                pos = next;
            }
        }
        block += 1;
    }
    return ok;
}

/* One record's `ssa` pass, folded into a checksum over the early-out taken, the
 * candidate and phi counts, the self-check outcomes and every materialized
 * instruction's destination and resolved operands. */
static uint64_t ssa_function(void) {
    uint64_t hash = SSA_HASH_BASIS;
    int64_t block = 0;
    ssa_build_context();
    ssa_verify_ok = -1;
    if (ssa_input_single_defs()) {
        return ssa_mix(hash, 1);
    }
    ssa_build_facts();
    ssa_site_count = 0;
    ssa_cand_count = ssa_count_candidates();
    if (ssa_candidate_phi_dst()) {
        hash = ssa_mix(hash, 2);
    } else if (ssa_cand_count == 0) {
        hash = ssa_mix(hash, 3);
    } else if (ssa_nblocks > 4096) {
        hash = ssa_mix(hash, 4);
    } else if (ssa_entry_has_preds()) {
        hash = ssa_mix(hash, 5);
    } else {
        ssa_insert_phis();
        ssa_rename();
        ssa_materialize();
        hash = ssa_mix(hash, 6);
        hash = ssa_mix(hash, ssa_site_count);
        hash = ssa_mix(hash, ssa_next_var);
        hash = ssa_mix(hash, ssa_next_var - ssa_phi_next);
        ssa_verify_ok = ssa_verify();
        hash = ssa_mix(hash, ssa_verify_ok);
        while (block < ssa_nblocks) {
            int64_t pos = ssa_mt_base[block];
            int64_t stop = ssa_mt_base[block] + ssa_mt_len[block];
            while (pos < stop) {
                int64_t next = ssa_instr_next(ssa_mt, pos);
                int64_t i = 1;
                hash = ssa_mix(hash, ssa_mt[pos]);
                while (pos + i < next) {
                    hash = ssa_mix(hash, ssa_mt[pos + i]);
                    i += 1;
                }
                pos = next;
            }
            block += 1;
        }
    }
    hash = ssa_mix(hash, ssa_cand_count);
    hash = ssa_mix(hash, ssa_cand_count == ssa_exp_cands ? 1 : 0);
    hash = ssa_mix(hash, ssa_site_count == ssa_exp_phis ? 1 : 0);
    hash = ssa_mix(hash, (ssa_verify_ok == -1 || ssa_verify_ok == ssa_exp_verify)
                             ? 1
                             : 0);
    return hash;
}

static int64_t ssa_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = ssa_read_file(path, &length);
    int64_t capacity = length / 2 + 8;
    int64_t functions = 0;
    int64_t cursor = 1;
    int64_t max_frame = 1;
    int64_t max_blocks = 1;
    int64_t max_instrs = 1;
    int64_t max_edges = 1;
    int64_t max_span = 1;
    int64_t max_phis = 1;
    int64_t map_capacity = 64;
    int64_t round = 0;
    int64_t start = 0;
    int64_t f = 0;
    uint64_t acc = SSA_HASH_BASIS;

    ssa_tokens = ssa_alloc(capacity);
    acc = ssa_mix(acc, ssa_scan_ints(text, length, ssa_tokens));
    functions = ssa_tokens[0];
    ssa_offsets = ssa_alloc(functions + 1);
    while (f < functions) {
        int64_t frame = ssa_tokens[cursor];
        int64_t params = ssa_tokens[cursor + 1];
        int64_t blocks = ssa_tokens[cursor + 2];
        int64_t instrs = ssa_tokens[cursor + 3];
        int64_t phis = ssa_tokens[cursor + 5];
        int64_t edges = 0;
        int64_t pos = cursor + 7 + 2 * params;
        int64_t block = 0;
        ssa_offsets[f] = cursor;
        while (block < blocks) {
            int64_t succs = ssa_tokens[pos];
            int64_t count;
            int64_t k = 0;
            edges += succs;
            pos = pos + 1 + succs;
            count = ssa_tokens[pos];
            pos += 1;
            while (k < count) {
                pos = ssa_instr_next(ssa_tokens, pos);
                k += 1;
            }
            block += 1;
        }
        if (frame > max_frame) {
            max_frame = frame;
        }
        if (blocks > max_blocks) {
            max_blocks = blocks;
        }
        if (instrs > max_instrs) {
            max_instrs = instrs;
        }
        if (edges > max_edges) {
            max_edges = edges;
        }
        if (phis > max_phis) {
            max_phis = phis;
        }
        if (pos - cursor > max_span) {
            max_span = pos - cursor;
        }
        cursor = pos;
        f += 1;
    }
    while (map_capacity < 4 * (max_frame + max_phis)) {
        map_capacity *= 2;
    }
    ssa_map_stride = map_capacity;
    ssa_site_cap = max_phis;
    ssa_out_stride = max_frame + 1;
    ssa_succ_off = ssa_alloc(max_blocks + 2);
    ssa_succ_edge = ssa_alloc(max_edges + 2);
    ssa_pred_off = ssa_alloc(max_blocks + 2);
    ssa_pred_edge = ssa_alloc(max_edges + 2);
    ssa_pred_fill = ssa_alloc(max_blocks + 2);
    ssa_blk_base = ssa_alloc(max_blocks + 2);
    ssa_blk_count = ssa_alloc(max_blocks + 2);
    ssa_reachable = ssa_alloc(max_blocks + 2);
    ssa_postorder = ssa_alloc(max_blocks + 2);
    ssa_rpo = ssa_alloc(max_blocks + 2);
    ssa_rpo_num = ssa_alloc(max_blocks + 2);
    ssa_idom = ssa_alloc(max_blocks + 2);
    ssa_tin = ssa_alloc(max_blocks + 2);
    ssa_tout = ssa_alloc(max_blocks + 2);
    ssa_child_off = ssa_alloc(max_blocks + 2);
    ssa_child_edge = ssa_alloc(max_blocks + 2);
    ssa_child_fill = ssa_alloc(max_blocks + 2);
    ssa_stack_node = ssa_alloc(max_blocks + 2);
    ssa_stack_edge = ssa_alloc(max_blocks + 2);
    ssa_map_keys = ssa_alloc(2 * map_capacity);
    ssa_map_vals = ssa_alloc(2 * map_capacity);
    ssa_map_state = ssa_alloc(2 * map_capacity);
    ssa_map_scratch_key = ssa_alloc(map_capacity + 1);
    ssa_map_scratch_val = ssa_alloc(map_capacity + 1);
    ssa_map_scratch_state = ssa_alloc(map_capacity + 1);
    ssa_ty = ssa_alloc(max_frame + 1);
    ssa_ty_order = ssa_alloc(max_frame + 1);
    ssa_vb_by_var = ssa_alloc(max_frame + 1);
    ssa_vb_len = ssa_alloc(max_frame + 1);
    ssa_vb_items = ssa_alloc(max_frame * max_blocks + 1);
    ssa_vb_members = ssa_alloc(max_frame * max_blocks + 1);
    ssa_site_var = ssa_alloc(max_phis + 2);
    ssa_site_label = ssa_alloc(max_phis + 2);
    ssa_site_ty = ssa_alloc(max_phis + 2);
    ssa_site_phivar = ssa_alloc(max_phis + 2);
    ssa_work_members = ssa_alloc(max_blocks + 2);
    ssa_site_members = ssa_alloc(max_blocks + 2);
    ssa_worklist = ssa_alloc(2 * max_blocks + 2);
    ssa_df_set = ssa_alloc(max_blocks + 2);
    ssa_env_by_var = ssa_alloc(max_frame + max_phis + 2);
    ssa_env_current = ssa_alloc(max_frame + 2);
    ssa_env_present = ssa_alloc(max_frame + 2);
    ssa_chg_slot = ssa_alloc(max_instrs + max_phis + max_frame + 2);
    ssa_chg_val = ssa_alloc(max_instrs + max_phis + max_frame + 2);
    ssa_chg_present = ssa_alloc(max_instrs + max_phis + max_frame + 2);
    ssa_w_id = ssa_alloc(2 * max_blocks + 2);
    ssa_w_exit = ssa_alloc(2 * max_blocks + 2);
    ssa_w_chk = ssa_alloc(2 * max_blocks + 2);
    ssa_child_head = ssa_alloc(max_blocks + 2);
    ssa_child_link = ssa_alloc(max_blocks + 2);
    ssa_rb_label = ssa_alloc(max_blocks + 2);
    ssa_rb_base = ssa_alloc(max_blocks + 2);
    ssa_rb_len = ssa_alloc(max_blocks + 2);
    ssa_rn = ssa_alloc(max_span + 2);
    ssa_out_label = ssa_alloc(max_blocks + 2);
    ssa_out_entry = ssa_alloc(max_blocks + 2);
    ssa_out_cur = ssa_alloc((max_blocks + 1) * ssa_out_stride + 1);
    ssa_out_pres = ssa_alloc((max_blocks + 1) * ssa_out_stride + 1);
    ssa_mt = ssa_alloc(max_span + max_phis * (4 + 2 * max_edges) + 2);
    ssa_mt_base = ssa_alloc(max_blocks + 2);
    ssa_mt_len = ssa_alloc(max_blocks + 2);
    ssa_def_blk = ssa_alloc(max_frame + max_phis + max_instrs + 2);
    ssa_def_pos = ssa_alloc(max_frame + max_phis + max_instrs + 2);
    ssa_def_seen = ssa_alloc(max_frame + max_phis + max_instrs + 2);

    while (round < rounds) {
        int64_t step = 0;
        acc = ssa_mix(acc, round);
        while (step < functions) {
            int64_t index = start + step;
            if (index >= functions) {
                index -= functions;
            }
            ssa_load_function(ssa_offsets[index]);
            acc = ssa_mix(acc, (int64_t)ssa_function());
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
    printf("%lld\n", (long long)ssa_bench(path, rounds));
    return 0;
}
