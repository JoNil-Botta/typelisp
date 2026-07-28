/* benchmarks/gvn_table/baseline.c - clang C baseline for gvn_table.
 *
 * Equivalent to benchmarks/gvn_table/bench.tl: the TypeLisp optimizer's
 * block-local redundant-load elimination -- the per-instruction dispatch that
 * drives a linked-list load table, an alias-fact hash map and a dense
 * pointer-kind environment -- run over real instruction tapes captured at
 * `--dump-ir after-ssa`, the dump point immediately before the `gvn` pass.
 *
 * Mirrored compiler functions (all in src/compiler_optimize.tl) and the exact
 * kept/dropped list are documented in bench.tl and README.md.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum and the map's
 * `key * 6364136223846793005` hash are formed in uint64_t so the C side wraps
 * identically. The printed decimal is the checksum reinterpreted as a signed
 * 64-bit integer, matching TypeLisp's print of an i64.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define GVN_HASH_BASIS 1469598103934665603ULL
#define GVN_HASH_PRIME 1099511628211ULL

/* opt-load-cse-table-cap-floor / -kinds-cap-floor / -cap-hard-max */
#define GVN_TABLE_CAP_FLOOR 128
#define GVN_KINDS_CAP_FLOOR 96
#define GVN_CAP_HARD_MAX 2048

/* opt-load-loc-kind-* packing limits. */
#define GVN_FIELD_BASE_LIMIT 1073741824LL
#define GVN_FIELD_OFFSET_LIMIT 1048576LL
#define GVN_FIELD_WIDTH_LIMIT 512LL

#define GVN_MISS (-1000000LL)

enum {
    GVN_OP_OTHER = 0,
    GVN_OP_GEP = 1,
    GVN_OP_LOAD = 2,
    GVN_OP_STORE = 3,
    GVN_OP_CALL = 4,
    GVN_OP_MOV = 5,
    GVN_OP_ALLOC = 6,
    GVN_OP_CLEARALL = 7,
    GVN_OP_COPY = 8,
    GVN_OP_CAST = 9,
    GVN_OP_MAYALIAS = 10
};

static int64_t *gvn_tokens;
static int64_t *gvn_offsets;
static int64_t *gvn_ty_width;
static int64_t *gvn_ty_int;
static int64_t *gvn_header;
static int64_t gvn_header_len;

static int64_t *gvn_kinds;
static int64_t gvn_kinds_slots;
static int64_t *gvn_kind_stamps;
static int64_t *gvn_kind_pos;
static int64_t *gvn_refs;
static int64_t *gvn_ref_stamps;
static int64_t *gvn_active;
static int64_t gvn_active_len_slots;
static int64_t gvn_kinds_len;
static int64_t gvn_kinds_gen = 1;
static int64_t gvn_kinds_cap = GVN_KINDS_CAP_FLOOR;

static int64_t *gvn_fact_key;
static int64_t *gvn_fact_val;
static int64_t *gvn_fact_state;
static int64_t *gvn_fact_scratch_key;
static int64_t *gvn_fact_scratch_val;
static int64_t gvn_fact_cap = 32;
static int64_t gvn_fact_len;
static int64_t gvn_fact_deleted;

static int64_t *gvn_node_kind;
static int64_t *gvn_node_a;
static int64_t *gvn_node_b;
static int64_t *gvn_node_ty;
static int64_t *gvn_node_width;
static int64_t *gvn_node_hdr;
static int64_t *gvn_node_val;
static int64_t *gvn_node_epoch;
static int64_t *gvn_node_next;
static int64_t gvn_node_bump;
static int64_t gvn_node_free = -1;
static int64_t gvn_table = -1;
static int64_t gvn_table_cap = GVN_TABLE_CAP_FLOOR;
static int64_t gvn_epoch;

static int64_t *gvn_copy_base;
static int64_t *gvn_copy_off;
static int64_t *gvn_copy_ty;
static int64_t *gvn_copy_width;
static int64_t *gvn_copy_val;

static int64_t gvn_k_tag;
static int64_t gvn_k_base;
static int64_t gvn_k_off;
static int64_t gvn_k_width;
static int64_t gvn_k_hdr;

static int64_t gvn_key_kind;
static int64_t gvn_key_a;
static int64_t gvn_key_b;
static int64_t gvn_key_ty;
static int64_t gvn_key_width;
static int64_t gvn_key_hdr;

static int64_t gvn_root_kind;
static int64_t gvn_root_id;
static int64_t gvn_root_epoch;

static int64_t gvn_hits;
static int64_t gvn_misses;
static int64_t gvn_invalidations;

static uint64_t gvn_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * GVN_HASH_PRIME;
}

static int64_t *gvn_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static char *gvn_read_file(const char *path, int64_t *length) {
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

static int64_t gvn_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int gvn_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

static int64_t gvn_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = gvn_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && gvn_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (gvn_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (gvn_digit(gvn_byte_at(text, n, i))) {
                value = value * 10 + (gvn_byte_at(text, n, i) - 48);
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

/* opt-load-cse-scaled-cap */
static int64_t gvn_scaled_cap(int64_t floor_value, int64_t instrs) {
    int64_t from_size = instrs / 2;
    int64_t with_floor = from_size > floor_value ? from_size : floor_value;
    return with_floor > GVN_CAP_HARD_MAX ? GVN_CAP_HARD_MAX : with_floor;
}

/* --- alias facts map ------------------------------------------------------ */

static void gvn_facts_reset(void) {
    int64_t i;
    for (i = 0; i < gvn_fact_cap; i += 1) {
        gvn_fact_state[i] = 0;
    }
    gvn_fact_cap = 32;
    gvn_fact_len = 0;
    gvn_fact_deleted = 0;
}

/* stdlib/hashmap.tl `probe`: linear probing over a power-of-two capacity, with
 * the first tombstone reused for an absent key. A non-negative result is the
 * occupied slot; -(index + 2) is the slot an insert would take. */
static int64_t gvn_facts_slot(int64_t key) {
    int64_t mask = gvn_fact_cap - 1;
    int64_t cursor = (int64_t)(((uint64_t)key * 6364136223846793005ULL) &
                               (uint64_t)mask);
    int64_t walked = 0;
    int64_t first = -1;
    int64_t found = -1;
    int done = 0;
    while (walked < gvn_fact_cap && !done) {
        int64_t state = gvn_fact_state[cursor];
        if (state == 2) {
            if (gvn_fact_key[cursor] == key) {
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

static void gvn_facts_grow(void) {
    int64_t old_cap = gvn_fact_cap;
    int64_t live = 0;
    int64_t i;
    for (i = 0; i < old_cap; i += 1) {
        if (gvn_fact_state[i] == 2) {
            gvn_fact_scratch_key[live] = gvn_fact_key[i];
            gvn_fact_scratch_val[live] = gvn_fact_val[i];
            live += 1;
        }
    }
    gvn_fact_cap = old_cap * 2;
    for (i = 0; i < gvn_fact_cap; i += 1) {
        gvn_fact_state[i] = 0;
    }
    gvn_fact_len = 0;
    gvn_fact_deleted = 0;
    for (i = 0; i < live; i += 1) {
        int64_t slot = gvn_facts_slot(gvn_fact_scratch_key[i]);
        int64_t index = -slot - 2;
        gvn_fact_state[index] = 2;
        gvn_fact_key[index] = gvn_fact_scratch_key[i];
        gvn_fact_val[index] = gvn_fact_scratch_val[i];
        gvn_fact_len += 1;
    }
}

static void gvn_facts_insert(int64_t key, int64_t value) {
    int64_t slot;
    if ((gvn_fact_len + gvn_fact_deleted) * 4 >= gvn_fact_cap * 3) {
        gvn_facts_grow();
    }
    slot = gvn_facts_slot(key);
    if (slot >= 0) {
        gvn_fact_val[slot] = value;
    } else {
        int64_t index = -slot - 2;
        if (gvn_fact_state[index] == 1) {
            gvn_fact_deleted -= 1;
        }
        gvn_fact_state[index] = 2;
        gvn_fact_key[index] = key;
        gvn_fact_val[index] = value;
        gvn_fact_len += 1;
    }
}

static void gvn_facts_remove(int64_t key) {
    int64_t slot = gvn_facts_slot(key);
    if (slot >= 0) {
        gvn_fact_state[slot] = 1;
        gvn_fact_len -= 1;
        gvn_fact_deleted += 1;
    }
}

/* --- alias kinds ---------------------------------------------------------- */

static void gvn_alias_mark_may_alias(int64_t var) { gvn_facts_insert(var, -4); }

/* opt-alias-copy-var */
static void gvn_alias_copy_var(int64_t dst, int64_t src) {
    int64_t slot = gvn_facts_slot(src);
    if (slot >= 0) {
        int64_t code = gvn_fact_val[slot];
        if (dst != src) {
            if (code >= 0) {
                gvn_facts_insert(dst, code);
            } else if (code == -2 || code == -3 || code <= -6) {
                gvn_facts_insert(dst, src);
            } else {
                gvn_alias_mark_may_alias(dst);
            }
        }
    } else {
        gvn_alias_mark_may_alias(dst);
    }
}

/* opt-alias-derive-var */
static void gvn_alias_derive_var(int64_t dst, int64_t base) {
    int64_t slot = gvn_facts_slot(base);
    if (slot >= 0) {
        int64_t code = gvn_fact_val[slot];
        if (code >= 0) {
            gvn_facts_insert(dst, code);
        } else if (code == -2 || code == -3 || code <= -6) {
            gvn_facts_insert(dst, base);
        } else {
            gvn_alias_mark_may_alias(dst);
        }
    } else {
        gvn_alias_mark_may_alias(dst);
    }
}

/* opt-alias-root-of-var */
static void gvn_root_of_var(int64_t var) {
    int64_t slot = gvn_facts_slot(var);
    gvn_root_kind = 0;
    gvn_root_id = 0;
    gvn_root_epoch = 0;
    if (slot >= 0) {
        int64_t code = gvn_fact_val[slot];
        if (code <= -6) {
            gvn_root_kind = 1;
            gvn_root_id = var;
            gvn_root_epoch = -code - 6;
        } else if (code == -2) {
            gvn_root_kind = 2;
            gvn_root_id = var;
        } else if (code == -3) {
            gvn_root_kind = 3;
            gvn_root_id = var;
        } else if (code >= 0) {
            int64_t root_slot = gvn_facts_slot(code);
            if (root_slot >= 0) {
                int64_t root_code = gvn_fact_val[root_slot];
                if (root_code <= -6) {
                    gvn_root_kind = 1;
                    gvn_root_id = code;
                    gvn_root_epoch = -root_code - 6;
                } else if (root_code == -2) {
                    gvn_root_kind = 2;
                    gvn_root_id = code;
                } else if (root_code == -3) {
                    gvn_root_kind = 3;
                    gvn_root_id = code;
                }
            }
        }
    }
}

static void gvn_root_of_value(int64_t value) {
    if (value >= 0) {
        gvn_root_of_var(value);
    } else {
        gvn_root_kind = 0;
        gvn_root_id = 0;
        gvn_root_epoch = 0;
    }
}

/* opt-alias-store-root-disjoint? */
static int gvn_root_disjoint(int64_t store_kind, int64_t store_id,
                             int64_t entry_kind, int64_t entry_id) {
    if (store_kind == 1 || store_kind == 2) {
        if (entry_kind == 0) {
            return 0;
        }
        return store_id != entry_id;
    }
    return 0;
}

/* --- pointer kinds -------------------------------------------------------- */

static int64_t gvn_kind_encode(int64_t tag, int64_t base, int64_t off,
                               int64_t width, int64_t hdr) {
    if (tag == 0) {
        return 0;
    }
    if (tag == 1) {
        return 1;
    }
    return (tag == 2 ? 2 : 3) + hdr * 4 + width * 8 + (off << 12) + (base << 32);
}

/* opt-load-loc-kind-decode. Every packing scale is a power of two, so the
 * compiler's `/` and `%` are these shifts and masks exactly. */
static void gvn_kind_decode(int64_t value) {
    if (value == 0) {
        gvn_k_tag = 0;
        gvn_k_base = 0;
        gvn_k_off = 0;
        gvn_k_width = 0;
        gvn_k_hdr = 0;
    } else if (value == 1) {
        gvn_k_tag = 1;
        gvn_k_base = 0;
        gvn_k_off = 0;
        gvn_k_width = 0;
        gvn_k_hdr = 0;
    } else {
        gvn_k_tag = (value & 1) == 1 ? 3 : 2;
        gvn_k_base = value >> 32;
        gvn_k_off = (value >> 12) & 1048575;
        gvn_k_width = (value >> 3) & 511;
        gvn_k_hdr = (value >> 2) & 1;
    }
}

static void gvn_kinds_lookup(int64_t var) {
    if (var < 0 || var >= gvn_kinds_slots || gvn_kind_stamps[var] != gvn_kinds_gen) {
        gvn_kind_decode(0);
    } else {
        gvn_kind_decode(gvn_kinds[var]);
    }
}

static int64_t gvn_kinds_ref_count(int64_t base) {
    if (base < 0 || base >= gvn_kinds_slots || gvn_ref_stamps[base] != gvn_kinds_gen) {
        return 0;
    }
    return gvn_refs[base];
}

static void gvn_kinds_ref_add(int64_t base, int64_t delta) {
    if (base >= 0 && base < gvn_kinds_slots) {
        int64_t old = gvn_ref_stamps[base] == gvn_kinds_gen ? gvn_refs[base] : 0;
        gvn_ref_stamps[base] = gvn_kinds_gen;
        gvn_refs[base] = old + delta;
    }
}

static void gvn_kinds_ref_add_kind(int64_t tag, int64_t base, int64_t off,
                                   int64_t delta) {
    if (tag == 2) {
        gvn_kinds_ref_add(base, delta);
    } else if (tag == 3) {
        gvn_kinds_ref_add(base, delta);
        gvn_kinds_ref_add(off, delta);
    }
}

/* opt-load-kinds-remove (dense arm): swap-remove from the active vector. */
static void gvn_kinds_remove(int64_t var) {
    if (var >= 0 && var < gvn_kinds_slots && gvn_kind_stamps[var] == gvn_kinds_gen) {
        int64_t old = gvn_kinds[var];
        int64_t pos = gvn_kind_pos[var];
        int64_t last_pos = gvn_kinds_len - 1;
        int64_t last_var = gvn_active[last_pos];
        gvn_kind_decode(old);
        gvn_kinds_ref_add_kind(gvn_k_tag, gvn_k_base, gvn_k_off, -1);
        if (pos != last_pos) {
            gvn_active[pos] = last_var;
            gvn_kind_pos[last_var] = pos;
        }
        gvn_kind_stamps[var] = 0;
        gvn_kinds_len = last_pos;
    }
}

/* opt-load-kinds-bind (dense arm): Unknown removes; the env is size-capped. */
static void gvn_kinds_bind(int64_t var, int64_t tag, int64_t base, int64_t off,
                           int64_t width, int64_t hdr) {
    if (tag == 0) {
        gvn_kinds_remove(var);
        return;
    }
    gvn_kinds_remove(var);
    if (var >= 0 && var < gvn_kinds_slots && gvn_kinds_len < gvn_kinds_cap &&
        gvn_kinds_len < gvn_active_len_slots) {
        gvn_kinds_ref_add_kind(tag, base, off, 1);
        gvn_active[gvn_kinds_len] = var;
        gvn_kind_pos[var] = gvn_kinds_len;
        gvn_kinds[var] = gvn_kind_encode(tag, base, off, width, hdr);
        gvn_kind_stamps[var] = gvn_kinds_gen;
        gvn_kinds_len += 1;
    }
}

/* opt-load-loc-field-checked */
static void gvn_bind_field_checked(int64_t var, int64_t base, int64_t off,
                                   int64_t width, int64_t hdr) {
    if (base >= 0 && base < GVN_FIELD_BASE_LIMIT && off >= 0 &&
        off < GVN_FIELD_OFFSET_LIMIT && width > 0 && width < GVN_FIELD_WIDTH_LIMIT) {
        gvn_kinds_bind(var, 2, base, off, width, hdr);
    } else {
        gvn_kinds_bind(var, 0, 0, 0, 0, 0);
    }
}

/* opt-load-loc-scaled-field-checked */
static void gvn_bind_scaled_checked(int64_t var, int64_t base, int64_t index,
                                    int64_t width, int64_t hdr) {
    if (base >= 0 && base < GVN_FIELD_BASE_LIMIT && index >= 0 &&
        index < GVN_FIELD_OFFSET_LIMIT && width > 0 &&
        width < GVN_FIELD_WIDTH_LIMIT) {
        gvn_kinds_bind(var, 3, base, index, width, hdr);
    } else {
        gvn_kinds_bind(var, 0, 0, 0, 0, 0);
    }
}

/* opt-load-kinds-dense-drop-base-from */
static void gvn_kinds_drop_base(int64_t base) {
    int64_t index = 0;
    while (index < gvn_kinds_len) {
        int64_t bound = gvn_active[index];
        gvn_kinds_lookup(bound);
        if ((gvn_k_tag == 2 && gvn_k_base == base) ||
            (gvn_k_tag == 3 && (gvn_k_base == base || gvn_k_off == base))) {
            gvn_kinds_remove(bound);
        } else {
            index += 1;
        }
    }
}

/* opt-load-kinds-invalidate-def */
static void gvn_kinds_invalidate_def(int64_t var) {
    gvn_kinds_remove(var);
    if (gvn_kinds_ref_count(var) > 0) {
        gvn_kinds_drop_base(var);
    }
}

static int gvn_header_var(int64_t var) {
    if (var < 0 || var >= gvn_header_len) {
        return 0;
    }
    return gvn_header[var] == 1;
}

/* --- load table ----------------------------------------------------------- */

static int64_t gvn_node_alloc(void) {
    if (gvn_node_free >= 0) {
        int64_t node = gvn_node_free;
        gvn_node_free = gvn_node_next[node];
        return node;
    }
    return gvn_node_bump++;
}

static void gvn_node_release(int64_t head) {
    int64_t node = head;
    while (node >= 0) {
        int64_t next = gvn_node_next[node];
        gvn_node_next[node] = gvn_node_free;
        gvn_node_free = node;
        node = next;
    }
}

static int64_t gvn_node_copy(int64_t source) {
    int64_t node = gvn_node_alloc();
    gvn_node_kind[node] = gvn_node_kind[source];
    gvn_node_a[node] = gvn_node_a[source];
    gvn_node_b[node] = gvn_node_b[source];
    gvn_node_ty[node] = gvn_node_ty[source];
    gvn_node_width[node] = gvn_node_width[source];
    gvn_node_hdr[node] = gvn_node_hdr[source];
    gvn_node_val[node] = gvn_node_val[source];
    gvn_node_epoch[node] = gvn_node_epoch[source];
    gvn_node_next[node] = -1;
    return node;
}

/* opt-load-table-len */
static int64_t gvn_table_len(int64_t head) {
    int64_t node = head;
    int64_t count = 0;
    while (node >= 0) {
        count += 1;
        node = gvn_node_next[node];
    }
    return count;
}

/* opt-load-key-eq against the key currently in the gvn_key_* globals. */
static int gvn_key_matches(int64_t node) {
    if (gvn_node_kind[node] != gvn_key_kind) {
        return 0;
    }
    if (gvn_key_kind == 0) {
        return gvn_node_a[node] == gvn_key_a && gvn_node_ty[node] == gvn_key_ty &&
               gvn_node_b[node] == gvn_key_b;
    }
    return gvn_node_a[node] == gvn_key_a && gvn_node_b[node] == gvn_key_b &&
           gvn_node_ty[node] == gvn_key_ty && gvn_node_hdr[node] == gvn_key_hdr;
}

/* opt-load-table-lookup */
static int64_t gvn_table_lookup(void) {
    int64_t node = gvn_table;
    int64_t result = GVN_MISS;
    while (node >= 0 && result == GVN_MISS) {
        if (gvn_key_matches(node)) {
            result = gvn_node_val[node];
        } else {
            node = gvn_node_next[node];
        }
    }
    return result;
}

/* opt-load-key-uses-var? */
static int gvn_key_uses_var(int64_t var) {
    if (gvn_key_kind == 0) {
        return gvn_key_a >= 0 && gvn_key_a == var;
    }
    if (gvn_key_kind == 1) {
        return gvn_key_a == var;
    }
    return gvn_key_a == var || gvn_key_b == var;
}

static int gvn_node_uses_var(int64_t node, int64_t var) {
    int64_t kind = gvn_node_kind[node];
    int64_t a = gvn_node_a[node];
    int64_t b = gvn_node_b[node];
    if (kind == 0) {
        return a >= 0 && a == var;
    }
    if (kind == 1) {
        return a == var;
    }
    return a == var || b == var;
}

/* opt-load-entry-mentions-var? */
static int gvn_node_mentions_var(int64_t node, int64_t var) {
    return (gvn_node_val[node] >= 0 && gvn_node_val[node] == var) ||
           gvn_node_uses_var(node, var);
}

/* opt-load-table-remove-key-scan */
static void gvn_table_remove_key(void) {
    int64_t node = gvn_table;
    int64_t head = -1;
    int64_t tail = -1;
    while (node >= 0) {
        if (!gvn_key_matches(node)) {
            int64_t fresh = gvn_node_copy(node);
            if (tail < 0) {
                head = fresh;
            } else {
                gvn_node_next[tail] = fresh;
            }
            tail = fresh;
        }
        node = gvn_node_next[node];
    }
    gvn_node_release(gvn_table);
    gvn_table = head;
}

/* opt-load-table-bind */
static void gvn_table_bind(int64_t value, int64_t epoch) {
    int64_t existing = gvn_table_lookup();
    if (existing != GVN_MISS) {
        gvn_table_remove_key();
    }
    if (existing != GVN_MISS || gvn_table_len(gvn_table) < gvn_table_cap) {
        int64_t node = gvn_node_alloc();
        gvn_node_kind[node] = gvn_key_kind;
        gvn_node_a[node] = gvn_key_a;
        gvn_node_b[node] = gvn_key_b;
        gvn_node_ty[node] = gvn_key_ty;
        gvn_node_width[node] = gvn_key_width;
        gvn_node_hdr[node] = gvn_key_hdr;
        gvn_node_val[node] = value;
        gvn_node_epoch[node] = epoch;
        gvn_node_next[node] = gvn_table;
        gvn_table = node;
    }
}

/* opt-load-table-invalidate-var */
static void gvn_table_invalidate_var(int64_t var) {
    int64_t node = gvn_table;
    int mentions = 0;
    while (node >= 0 && !mentions) {
        if (gvn_node_mentions_var(node, var)) {
            mentions = 1;
        } else {
            node = gvn_node_next[node];
        }
    }
    if (mentions) {
        int64_t scan = gvn_table;
        int64_t head = -1;
        int64_t tail = -1;
        while (scan >= 0) {
            if (gvn_node_mentions_var(scan, var)) {
                gvn_invalidations += 1;
            } else {
                int64_t fresh = gvn_node_copy(scan);
                if (tail < 0) {
                    head = fresh;
                } else {
                    gvn_node_next[tail] = fresh;
                }
                tail = fresh;
            }
            scan = gvn_node_next[scan];
        }
        gvn_node_release(gvn_table);
        gvn_table = head;
    }
}

/* opt-load-ranges-disjoint? */
static int gvn_ranges_disjoint(int64_t alo, int64_t awidth, int64_t blo,
                               int64_t bwidth) {
    return awidth > 0 && bwidth > 0 &&
           (alo + awidth <= blo || blo + bwidth <= alo);
}

/* opt-load-entry-survives-store-location? */
static int gvn_survives_location(int64_t node, int64_t class_tag,
                                 int64_t class_base, int64_t class_off,
                                 int64_t class_width, int64_t class_hdr) {
    int64_t kind = gvn_node_kind[node];
    if (class_tag == 1) {
        return kind == 1 && gvn_node_hdr[node] == 1;
    }
    if (class_tag == 2) {
        if (kind == 0) {
            return gvn_node_b[node] == 1 && class_hdr == 1;
        }
        if (kind == 1) {
            return gvn_node_a[node] == class_base &&
                   gvn_ranges_disjoint(class_off, class_width, gvn_node_b[node],
                                       gvn_node_width[node]);
        }
        return 0;
    }
    return 0;
}

/* opt-load-entry-survives-store? */
static int gvn_survives_store(int64_t node, int64_t store_kind, int64_t store_id,
                              int64_t store_epoch, int64_t class_tag,
                              int64_t class_base, int64_t class_off,
                              int64_t class_width, int64_t class_hdr) {
    int64_t kind = gvn_node_kind[node];
    int64_t entry_kind;
    int64_t entry_id;
    if (kind == 0) {
        gvn_root_of_value(gvn_node_a[node]);
    } else {
        gvn_root_of_var(gvn_node_a[node]);
    }
    entry_kind = gvn_root_kind;
    entry_id = gvn_root_id;
    return gvn_root_disjoint(store_kind, store_id, entry_kind, entry_id) ||
           (store_kind == 1 && gvn_node_epoch[node] < store_epoch) ||
           gvn_survives_location(node, class_tag, class_base, class_off,
                                 class_width, class_hdr);
}

/* opt-load-table-filter-store */
static void gvn_table_filter_store(int64_t store_kind, int64_t store_id,
                                   int64_t store_epoch, int64_t class_tag,
                                   int64_t class_base, int64_t class_off,
                                   int64_t class_width, int64_t class_hdr) {
    int64_t node = gvn_table;
    int64_t head = -1;
    int64_t tail = -1;
    while (node >= 0) {
        if (gvn_survives_store(node, store_kind, store_id, store_epoch, class_tag,
                               class_base, class_off, class_width, class_hdr)) {
            int64_t fresh = gvn_node_copy(node);
            if (tail < 0) {
                head = fresh;
            } else {
                gvn_node_next[tail] = fresh;
            }
            tail = fresh;
        } else {
            gvn_invalidations += 1;
        }
        node = gvn_node_next[node];
    }
    gvn_node_release(gvn_table);
    gvn_table = head;
}

static void gvn_table_clear(void) {
    gvn_invalidations += gvn_table_len(gvn_table);
    gvn_node_release(gvn_table);
    gvn_table = -1;
}

/* opt-load-table-has-value-with-type? */
static int gvn_table_has_value(int64_t value, int64_t ty) {
    int64_t node = gvn_table;
    int found = 0;
    while (node >= 0 && !found) {
        if (gvn_node_val[node] == value && gvn_node_ty[node] == ty) {
            found = 1;
        } else {
            node = gvn_node_next[node];
        }
    }
    return found;
}

/* opt-load-table-transfer-copy-fields plus opt-load-copy-entry-within? */
static void gvn_table_transfer_copy(int64_t src_base, int64_t src_off,
                                    int64_t dst_base, int64_t dst_off,
                                    int64_t size, int64_t dst_hdr,
                                    int64_t epoch) {
    int64_t node = gvn_table;
    int64_t count = 0;
    int64_t i;
    while (node >= 0) {
        if (gvn_node_kind[node] == 1 && gvn_node_a[node] == src_base &&
            gvn_node_width[node] > 0 && gvn_node_b[node] >= src_off &&
            gvn_node_b[node] + gvn_node_width[node] <= src_off + size) {
            gvn_copy_base[count] = gvn_node_a[node];
            gvn_copy_off[count] = gvn_node_b[node];
            gvn_copy_ty[count] = gvn_node_ty[node];
            gvn_copy_width[count] = gvn_node_width[node];
            gvn_copy_val[count] = gvn_node_val[node];
            count += 1;
        }
        node = gvn_node_next[node];
    }
    for (i = 0; i < count; i += 1) {
        gvn_key_kind = 1;
        gvn_key_a = dst_base;
        gvn_key_b = dst_off + (gvn_copy_off[i] - src_off);
        gvn_key_ty = gvn_copy_ty[i];
        gvn_key_width = gvn_copy_width[i];
        gvn_key_hdr = dst_hdr;
        gvn_table_bind(gvn_copy_val[i], epoch);
    }
}

/* --- per-instruction dispatch --------------------------------------------- */

/* opt-load-classify-store, written into the gvn_k_* globals reinterpreted as
 * (class, base, off, width, hdr). */
static void gvn_classify_store(int64_t ptr, int64_t width) {
    if (width <= 0 || ptr < 0) {
        gvn_k_tag = 0;
        gvn_k_base = 0;
        gvn_k_off = 0;
        gvn_k_width = 0;
        gvn_k_hdr = 0;
        return;
    }
    gvn_kinds_lookup(ptr);
    if (gvn_k_tag == 2) {
        gvn_k_width = width;
    } else if (gvn_k_tag == 3) {
        gvn_k_tag = 1;
    }
}

/* opt-load-key-for-address */
static void gvn_key_for_address(int64_t addr, int64_t raw, int64_t ty,
                                int64_t width) {
    gvn_key_ty = ty;
    gvn_key_width = width;
    if (addr >= 0) {
        gvn_kinds_lookup(addr);
        if (gvn_k_tag == 2) {
            gvn_key_kind = 1;
            gvn_key_a = gvn_k_base;
            gvn_key_b = gvn_k_off;
            gvn_key_hdr = gvn_k_hdr;
        } else if (gvn_k_tag == 3) {
            gvn_key_kind = 2;
            gvn_key_a = gvn_k_base;
            gvn_key_b = gvn_k_off;
            gvn_key_hdr = gvn_k_hdr;
        } else if (gvn_k_tag == 1) {
            gvn_key_kind = 0;
            gvn_key_a = addr;
            gvn_key_b = 1;
            gvn_key_hdr = 0;
        } else {
            gvn_key_kind = 0;
            gvn_key_a = addr;
            gvn_key_b = 0;
            gvn_key_hdr = 0;
        }
    } else {
        gvn_key_kind = 0;
        gvn_key_a = -(raw + 2);
        gvn_key_b = 0;
        gvn_key_hdr = 0;
    }
}

/* opt-load-kinds-step */
static void gvn_kinds_step(int64_t op, int64_t dst, int64_t a, int64_t b,
                           int64_t c, int64_t d) {
    if (dst >= 0) {
        gvn_kinds_invalidate_def(dst);
    }
    if (op == GVN_OP_GEP) {
        if (a >= 0) {
            gvn_kinds_lookup(a);
            if (gvn_k_tag == 1) {
                if (b == 1) {
                    gvn_bind_scaled_checked(dst, a, c, d, 0);
                } else {
                    gvn_kinds_bind(dst, 1, 0, 0, 0, 0);
                }
            } else if (gvn_k_tag == 2) {
                int64_t base0 = gvn_k_base;
                int64_t off0 = gvn_k_off;
                int64_t hdr0 = gvn_k_hdr;
                if (b == 0) {
                    if (d > 0) {
                        gvn_bind_field_checked(dst, base0, off0 + c * d, d, hdr0);
                    }
                } else if (off0 == 0) {
                    gvn_bind_scaled_checked(dst, base0, c, d, hdr0);
                }
            } else if (gvn_k_tag == 3) {
                gvn_kinds_bind(dst, 1, 0, 0, 0, 0);
            } else {
                if (b == 0 && d > 0 && a != dst) {
                    gvn_bind_field_checked(dst, a, c * d, d,
                                           gvn_header_var(a) ? 1 : 0);
                }
            }
        }
    } else if (op == GVN_OP_LOAD) {
        if (a >= 0) {
            gvn_kinds_lookup(a);
            if (gvn_k_tag == 2) {
                if (gvn_k_hdr == 1 && gvn_k_off == 0 && c == 8) {
                    gvn_kinds_bind(dst, 1, 0, 0, 0, 0);
                }
            } else if (gvn_header_var(a) && c == 8) {
                gvn_kinds_bind(dst, 1, 0, 0, 0, 0);
            }
        }
    } else if (op == GVN_OP_MOV) {
        if (a >= 0) {
            gvn_kinds_lookup(a);
            if (gvn_k_tag == 1) {
                gvn_kinds_bind(dst, 1, 0, 0, 0, 0);
            } else if (gvn_k_tag == 2) {
                gvn_kinds_bind(dst, 2, gvn_k_base, gvn_k_off, gvn_k_width,
                               gvn_k_hdr);
            } else if (gvn_k_tag == 3) {
                gvn_kinds_bind(dst, 3, gvn_k_base, gvn_k_off, gvn_k_width,
                               gvn_k_hdr);
            }
        }
    }
}

/* opt-load-alias-update-facts / opt-alias-update-value-facts */
static void gvn_alias_step(int64_t op, int64_t dst, int64_t a, int64_t b,
                           int64_t c, int64_t epoch) {
    if (op == GVN_OP_LOAD) {
        if (dst >= 0) {
            gvn_facts_remove(dst);
        }
        if (a >= 0) {
            gvn_kinds_lookup(a);
            if (gvn_k_tag == 2 && gvn_k_hdr == 1 && gvn_k_off == 0 && c == 8) {
                gvn_alias_derive_var(dst, a);
            } else {
                gvn_alias_mark_may_alias(dst);
            }
        } else {
            gvn_alias_mark_may_alias(dst);
        }
        return;
    }
    if (dst >= 0) {
        gvn_facts_remove(dst);
    }
    if (op == GVN_OP_ALLOC) {
        if (dst >= 0) {
            gvn_facts_insert(dst, -(6 + epoch));
        }
    } else if (op == GVN_OP_GEP) {
        if (a >= 0) {
            gvn_alias_derive_var(dst, a);
        } else {
            gvn_alias_mark_may_alias(dst);
        }
    } else if (op == GVN_OP_MOV || op == GVN_OP_CAST) {
        if (a >= 0) {
            gvn_alias_copy_var(dst, a);
        } else {
            gvn_alias_mark_may_alias(dst);
        }
    } else if (op == GVN_OP_CALL) {
        if (b == 1 && dst >= 0) {
            gvn_facts_insert(dst, -(6 + epoch));
        }
    } else if (op == GVN_OP_MAYALIAS) {
        gvn_alias_mark_may_alias(dst);
    }
}

/* opt-load-subword-store-forward-value */
static int64_t gvn_subword_forward(int64_t value, int64_t ty, int64_t width) {
    if (value == -1 || width <= 0) {
        return GVN_MISS;
    }
    if (value == -2 && gvn_ty_int[ty] == 1) {
        return -2;
    }
    if (value >= 0) {
        return gvn_table_has_value(value, ty) ? value : GVN_MISS;
    }
    return GVN_MISS;
}

/* opt-load-cse-state-store */
static void gvn_step_store(int64_t ptr, int64_t ty, int64_t width,
                           int64_t value) {
    int64_t class_tag;
    int64_t class_base;
    int64_t class_off;
    int64_t class_width;
    int64_t class_hdr;
    int64_t store_kind;
    int64_t store_id;
    int64_t store_epoch;
    int64_t forwarded = GVN_MISS;
    gvn_classify_store(ptr, width);
    class_tag = gvn_k_tag;
    class_base = gvn_k_base;
    class_off = gvn_k_off;
    class_width = gvn_k_width;
    class_hdr = gvn_k_hdr;
    gvn_root_of_value(ptr);
    store_kind = gvn_root_kind;
    store_id = gvn_root_id;
    store_epoch = gvn_root_epoch;
    if (class_tag != 0) {
        if (width == 8) {
            forwarded = value == -1 ? GVN_MISS : value;
        } else {
            forwarded = gvn_subword_forward(value, ty, width);
        }
    }
    gvn_table_filter_store(store_kind, store_id, store_epoch, class_tag,
                           class_base, class_off, class_width, class_hdr);
    if (class_tag != 0 && forwarded != GVN_MISS) {
        gvn_key_for_address(ptr, -1, ty, width);
        gvn_table_bind(forwarded, gvn_epoch);
    }
}

/* opt-load-cse-state-copy-bytes */
static void gvn_step_copy(int64_t dst, int64_t src, int64_t size) {
    int64_t class_tag;
    int64_t class_base;
    int64_t class_off;
    int64_t class_hdr;
    int64_t src_class;
    int64_t src_base;
    int64_t src_off;
    int64_t src_hdr;
    int64_t store_kind;
    int64_t store_id;
    int64_t store_epoch;
    gvn_classify_store(dst, size);
    class_tag = gvn_k_tag;
    class_base = gvn_k_base;
    class_off = gvn_k_off;
    class_hdr = gvn_k_hdr;
    gvn_classify_store(src, size);
    src_class = gvn_k_tag;
    src_base = gvn_k_base;
    src_off = gvn_k_off;
    src_hdr = gvn_k_hdr;
    gvn_root_of_value(dst);
    store_kind = gvn_root_kind;
    store_id = gvn_root_id;
    store_epoch = gvn_root_epoch;
    gvn_table_filter_store(store_kind, store_id, store_epoch, class_tag,
                           class_base, class_off, size, class_hdr);
    if (class_tag == 2 && src_class == 2 && src_base == class_base &&
        src_hdr == class_hdr &&
        gvn_ranges_disjoint(src_off, size, class_off, size)) {
        gvn_table_transfer_copy(src_base, src_off, class_base, class_off, size,
                                class_hdr, gvn_epoch);
    }
}

/* opt-load-cse-core-load */
static void gvn_step_load(int64_t dst, int64_t src, int64_t ty, int64_t width,
                          int64_t raw) {
    int64_t earlier;
    if (dst >= 0) {
        gvn_table_invalidate_var(dst);
    }
    gvn_key_for_address(src, raw, ty, width);
    earlier = gvn_table_lookup();
    if (earlier != GVN_MISS) {
        gvn_hits += 1;
        gvn_alias_step(GVN_OP_MOV, dst, earlier, 0, width, gvn_epoch);
        gvn_kinds_step(GVN_OP_MOV, dst, earlier, ty, width, 0);
    } else {
        int record;
        gvn_misses += 1;
        record = !gvn_key_uses_var(dst);
        gvn_alias_step(GVN_OP_LOAD, dst, src, 0, width, gvn_epoch);
        if (record) {
            gvn_table_bind(dst, gvn_epoch);
        }
        gvn_kinds_step(GVN_OP_LOAD, dst, src, 0, width, 0);
    }
}

/* opt-load-cse-state-direct-call */
static void gvn_step_call(int64_t dst, int64_t is_alloc, int64_t effect) {
    if (effect != 0) {
        gvn_table_clear();
    }
    if (is_alloc == 1) {
        gvn_epoch += 1;
    }
    gvn_alias_step(GVN_OP_CALL, dst, 0, is_alloc, 0, gvn_epoch);
    if (dst >= 0) {
        gvn_table_invalidate_var(dst);
    }
    gvn_kinds_step(GVN_OP_CALL, dst, -1, 0, 0, 0);
}

/* opt-load-cse-dispatch */
static void gvn_dispatch(int64_t op, int64_t dst, int64_t a, int64_t b,
                         int64_t c, int64_t d) {
    if (op == GVN_OP_STORE) {
        gvn_step_store(a, b, c, d);
    } else if (op == GVN_OP_COPY) {
        gvn_step_copy(a, b, c);
    } else if (op == GVN_OP_LOAD) {
        gvn_step_load(dst, a, b, c, d);
    } else if (op == GVN_OP_CALL) {
        gvn_step_call(dst, b, c);
    } else if (op == GVN_OP_CLEARALL) {
        gvn_table_clear();
        gvn_alias_step(op, dst, a, b, c, gvn_epoch);
        gvn_kinds_step(op, dst, a, b, c, d);
    } else {
        if (op == GVN_OP_ALLOC) {
            gvn_epoch += 1;
        }
        gvn_alias_step(op, dst, a, b, c, gvn_epoch);
        if (dst >= 0) {
            gvn_table_invalidate_var(dst);
        }
        gvn_kinds_step(op, dst, a, b, c, d);
    }
}

/* --- driver --------------------------------------------------------------- */

static uint64_t gvn_run_block(int64_t base, int64_t instrs, int64_t generation) {
    uint64_t hash;
    int64_t i = 0;
    int64_t cursor = base;
    gvn_table = -1;
    gvn_node_free = -1;
    gvn_node_bump = 0;
    gvn_epoch = 0;
    gvn_hits = 0;
    gvn_misses = 0;
    gvn_invalidations = 0;
    gvn_kinds_len = 0;
    gvn_kinds_gen = generation;
    gvn_table_cap = gvn_scaled_cap(GVN_TABLE_CAP_FLOOR, instrs);
    gvn_kinds_cap = gvn_scaled_cap(GVN_KINDS_CAP_FLOOR, instrs);
    gvn_facts_reset();
    while (i < instrs) {
        gvn_dispatch(gvn_tokens[cursor], gvn_tokens[cursor + 1],
                     gvn_tokens[cursor + 2], gvn_tokens[cursor + 3],
                     gvn_tokens[cursor + 4], gvn_tokens[cursor + 5]);
        cursor += 6;
        i += 1;
    }
    hash = gvn_mix(GVN_HASH_BASIS, gvn_hits);
    hash = gvn_mix(hash, gvn_misses);
    hash = gvn_mix(hash, gvn_invalidations);
    return gvn_mix(hash, gvn_table_len(gvn_table));
}

static uint64_t gvn_run_function(int64_t offset) {
    int64_t vars = gvn_tokens[offset];
    int64_t headers = gvn_tokens[offset + 1];
    int64_t blocks = gvn_tokens[offset + 2];
    int64_t cursor = offset + 3;
    uint64_t hash = GVN_HASH_BASIS;
    int64_t i;
    for (i = 0; i < vars; i += 1) {
        gvn_header[i] = 0;
        gvn_kind_stamps[i] = 0;
        gvn_ref_stamps[i] = 0;
    }
    for (i = 0; i < headers; i += 1) {
        gvn_header[gvn_tokens[cursor]] = 1;
        cursor += 1;
    }
    for (i = 0; i < blocks; i += 1) {
        int64_t instrs = gvn_tokens[cursor];
        hash = gvn_mix(hash,
                       (int64_t)gvn_run_block(cursor + 1, instrs, i * 2 + 1));
        cursor += 1 + instrs * 6;
    }
    return hash;
}

static int64_t gvn_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = gvn_read_file(path, &length);
    int64_t capacity = length / 2 + 8;
    int64_t types;
    int64_t functions;
    int64_t cursor;
    int64_t max_vars = 1;
    int64_t max_cap = GVN_TABLE_CAP_FLOOR;
    int64_t round = 0;
    int64_t start = 0;
    int64_t fact_cap = 32;
    int64_t pool;
    uint64_t acc = GVN_HASH_BASIS;
    int64_t t;
    int64_t f;

    gvn_tokens = gvn_alloc(capacity);
    acc = gvn_mix(acc, gvn_scan_ints(text, length, gvn_tokens));
    types = gvn_tokens[0];
    gvn_ty_width = gvn_alloc(types + 1);
    gvn_ty_int = gvn_alloc(types + 1);
    cursor = 1;
    for (t = 0; t < types; t += 1) {
        gvn_ty_width[t] = gvn_tokens[cursor];
        gvn_ty_int[t] = gvn_tokens[cursor + 1];
        cursor += 2;
    }
    functions = gvn_tokens[cursor];
    cursor += 1;
    gvn_offsets = gvn_alloc(functions + 1);
    for (f = 0; f < functions; f += 1) {
        int64_t vars = gvn_tokens[cursor];
        int64_t headers = gvn_tokens[cursor + 1];
        int64_t blocks = gvn_tokens[cursor + 2];
        int64_t scan = cursor + 3 + headers;
        int64_t b;
        gvn_offsets[f] = cursor;
        if (vars > max_vars) {
            max_vars = vars;
        }
        for (b = 0; b < blocks; b += 1) {
            int64_t instrs = gvn_tokens[scan];
            int64_t cap = gvn_scaled_cap(GVN_TABLE_CAP_FLOOR, instrs);
            if (cap > max_cap) {
                max_cap = cap;
            }
            scan += 1 + instrs * 6;
        }
        cursor = scan;
    }

    /* These three bounds must equal the TypeLisp array lengths exactly: the
     * range guards in gvn_kinds_lookup / gvn_kinds_bind / gvn_header_var are
     * observable. */
    gvn_header = gvn_alloc(max_vars + 1);
    gvn_header_len = max_vars + 1;
    gvn_kinds = gvn_alloc(max_vars + 1);
    gvn_kinds_slots = max_vars + 1;
    gvn_kind_stamps = gvn_alloc(max_vars + 1);
    gvn_kind_pos = gvn_alloc(max_vars + 1);
    gvn_refs = gvn_alloc(max_vars + 1);
    gvn_ref_stamps = gvn_alloc(max_vars + 1);
    gvn_active = gvn_alloc(max_vars + 1);
    gvn_active_len_slots = max_vars + 1;

    while (fact_cap < (max_vars + 4) * 8) {
        fact_cap *= 2;
    }
    gvn_fact_key = gvn_alloc(fact_cap);
    gvn_fact_val = gvn_alloc(fact_cap);
    gvn_fact_state = gvn_alloc(fact_cap);
    gvn_fact_scratch_key = gvn_alloc(fact_cap);
    gvn_fact_scratch_val = gvn_alloc(fact_cap);
    gvn_fact_cap = fact_cap;

    pool = max_cap * 4 + 128;
    gvn_node_kind = gvn_alloc(pool);
    gvn_node_a = gvn_alloc(pool);
    gvn_node_b = gvn_alloc(pool);
    gvn_node_ty = gvn_alloc(pool);
    gvn_node_width = gvn_alloc(pool);
    gvn_node_hdr = gvn_alloc(pool);
    gvn_node_val = gvn_alloc(pool);
    gvn_node_epoch = gvn_alloc(pool);
    gvn_node_next = gvn_alloc(pool);

    gvn_copy_base = gvn_alloc(max_cap + 2);
    gvn_copy_off = gvn_alloc(max_cap + 2);
    gvn_copy_ty = gvn_alloc(max_cap + 2);
    gvn_copy_width = gvn_alloc(max_cap + 2);
    gvn_copy_val = gvn_alloc(max_cap + 2);

    while (round < rounds) {
        int64_t step = 0;
        acc = gvn_mix(acc, round);
        while (step < functions) {
            int64_t index = start + step;
            if (index >= functions) {
                index -= functions;
            }
            acc = gvn_mix(acc, (int64_t)gvn_run_function(gvn_offsets[index]));
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
    printf("%lld\n", (long long)gvn_bench(path, rounds));
    return 0;
}
