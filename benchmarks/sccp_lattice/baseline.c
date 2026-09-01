/* benchmarks/sccp_lattice/baseline.c - clang C baseline for sccp_lattice.
 *
 * Equivalent to benchmarks/sccp_lattice/bench.tl: the TypeLisp optimizer's
 * `sccp` pass -- the scalar lattice, the CFG-id-backed executable flags, the
 * fixpoint sweep, the integer constant folder and the counted rewrite -- run
 * over real functions the compiler produced while compiling itself, captured
 * at `--dump-ir after-bounds_dom` (see README.md for the corpus).
 *
 * Mirrored compiler functions, all in src/compiler_optimize.tl unless noted:
 *   opt-sccp-blocks-with-context-result-raw / opt-sccp-analyze-with-frame
 *   opt-sccp-analyze-fixed        -- sweeps while something changed, bounded by
 *                                    nblocks + 8 + 2 * ninstr
 *   opt-sccp-initial-state-with-frame, opt-sccp-env-make / -fill-unknown! /
 *     -lookup / -set / -any-const?
 *   opt-sccp-join, opt-sccp-value-eq, opt-sccp-state-bind
 *   opt-sccp-state-mark-executable, opt-cfg-index-id / -id-slot /
 *     -id-map-capacity / -fill-id-map!
 *   opt-sccp-process-blocks-from / -process-block / -process-instr-seq-from /
 *     -process-instr
 *   opt-sccp-value, opt-sccp-immediate, opt-normalize-const,
 *     opt-default-immediate-type
 *   opt-sccp-fold-binop-value / -fold-unop-value / -fold-cast-value
 *   opt-fold-binop, opt-binop-operand-type, opt-fold-int-char-binop,
 *     opt-fold-bool, opt-fold-compare, opt-fold-shift, opt-shift-count-valid?,
 *     opt-divmod-valid?, opt-fold-div-value / -mod-value / -shl-value /
 *     -shr-value, opt-normalize-int-to-i64, opt-normalize-scalar-to-i64,
 *     opt-typed-lt? / -le? / -gt? / -ge?, opt-unsigned-lt?, opt-int-width
 *   opt-fold-unop, opt-fold-cast (over compiler_float.tl's
 *     compiler-finite-cast-fold / -normalize-i64 integer arms)
 *   opt-sccp-phi-value / -phi-input-value
 *   opt-sccp-mark-branch-targets / -mark-switch-targets
 *   opt-sccp-rewrite-value, opt-sccp-instr-changes-successors?,
 *     opt-sccp-blocks-change-successors?, opt-sccp-bounds-check-in-range?
 *
 * The lattice is held inline in a dense array indexed by var id, exactly as
 * `OptSccpValue` is held in `OptSccpEnv.Env`'s `(__tl_dyn-array OptSccpValue)`;
 * the array is allocated once at the corpus maximum and its capacity is
 * re-stamped to the function frame, so the range checks are the ones
 * `opt-sccp-env-make frame` produces. Recursion is written as recursion where
 * the compiler recurses (the instruction and block walks, the fixpoint, the
 * Unknown fill, the phi join, the any-const scan).
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum here is formed in
 * uint64_t so the C side wraps identically, and every wrapping fold result is
 * formed in uint64_t for the same reason. The printed decimal is the checksum
 * reinterpreted as a signed 64-bit integer, matching TypeLisp's print of an
 * i64.
 *
 * The self-check compares the five totals this kernel computes against the
 * exporter's own independent SCCP result, carried in the corpus header; a
 * mismatch makes `main` return 1.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define SCCP_HASH_BASIS 1469598103934665603ULL
#define SCCP_HASH_PRIME 1099511628211ULL

/* Type classes in the corpus type table. */
#define SCCP_CLASS_SINT 1
#define SCCP_CLASS_UINT 2
#define SCCP_CLASS_CHAR 3
#define SCCP_CLASS_BOOL 4

/* Pre-interned type ids (see tools/export_sccp_tape.py). */
#define SCCP_TY_I64 0
#define SCCP_TY_BOOL 1
#define SCCP_TY_CHAR 2
#define SCCP_TY_F64 3
#define SCCP_TY_F32 4

/* Operand kinds. */
#define SCCP_VK_NONE 0
#define SCCP_VK_VAR 1
#define SCCP_VK_INT 2
#define SCCP_VK_BOOL 3

/* Opcodes. */
#define SCCP_OP_OTHER 0
#define SCCP_OP_OVERDEF 1
#define SCCP_OP_MOV 2
#define SCCP_OP_CAST 3
#define SCCP_OP_PHI 4
#define SCCP_OP_JUMP 5
#define SCCP_OP_BRANCH 6
#define SCCP_OP_SWITCH 7
#define SCCP_OP_BOUNDS 8
#define SCCP_OP_NEG 9
#define SCCP_OP_NOT 10
#define SCCP_OP_BITNOT 11
#define SCCP_OP_SQRT 12
#define SCCP_OP_ADD 16
#define SCCP_OP_SUB 17
#define SCCP_OP_MUL 18
#define SCCP_OP_DIV 19
#define SCCP_OP_MOD 20
#define SCCP_OP_SAFE_DIV 21
#define SCCP_OP_SAFE_MOD 22
#define SCCP_OP_EQ 23
#define SCCP_OP_NE 24
#define SCCP_OP_LT 25
#define SCCP_OP_LE 26
#define SCCP_OP_GT 27
#define SCCP_OP_GE 28
#define SCCP_OP_BIT_TEST_EQ 29
#define SCCP_OP_BIT_TEST_NE 30
#define SCCP_OP_AND 31
#define SCCP_OP_OR 32
#define SCCP_OP_BIT_AND 33
#define SCCP_OP_BIT_OR 34
#define SCCP_OP_BIT_XOR 35
#define SCCP_OP_SHL 36
#define SCCP_OP_SHR 37

/* OptSccpValue: Unknown / Const (value kind, value bits, dense type id) /
 * Overdefined. */
#define SCCP_TAG_UNKNOWN 0
#define SCCP_TAG_CONST 1
#define SCCP_TAG_OVERDEFINED 2

typedef struct {
    int64_t tag;
    int64_t kind;
    int64_t value;
    int64_t ty;
} SccpValue;

/* Parsed corpus tokens plus the workspaces every per-function analysis reuses.
 * File-scope state keeps the analysis functions parameterless, matching how the
 * compiler threads one OptSccpState through the pass. */
static int64_t *sccp_tokens;
static int64_t *sccp_offsets;
static int64_t *sccp_type_class;
static int64_t *sccp_type_width;
static int64_t *sccp_labels;
static int64_t *sccp_idmap;
static SccpValue *sccp_env_slots;
static int64_t sccp_env_cap;
static unsigned char *sccp_exec_slots;

/* Per-function view of the corpus, set by sccp_bench before sccp_function. */
static int64_t sccp_frame;
static int64_t sccp_nparams;
static int64_t sccp_nblocks;
static int64_t sccp_ninstr;
static int64_t sccp_param_base;
static int64_t sccp_succ_base;
static int64_t sccp_phi_base;
static int64_t sccp_block_base;
static int64_t sccp_instr_base;
static int64_t sccp_idmask;

/* The `changed` field of OptSccpState, plus the totals the self-check pins. */
static int sccp_changed;
static int sccp_self_check_ok = 1;
static int64_t sccp_sweeps;
static int64_t sccp_consts;
static int64_t sccp_dead;
static int64_t sccp_subs;
static int64_t sccp_branches;
static int64_t sccp_dropped;

static uint64_t sccp_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * SCCP_HASH_PRIME;
}

static int64_t *sccp_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static char *sccp_read_file(const char *path, int64_t *length) {
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

static int64_t sccp_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int sccp_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t sccp_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = sccp_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && sccp_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (sccp_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (sccp_digit(sccp_byte_at(text, n, i))) {
                value = value * 10 + (sccp_byte_at(text, n, i) - 48);
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

/* --- type predicates (opt-integer-type? and friends) --------------------- */
static int64_t sccp_class_of(int64_t ty) { return sccp_type_class[ty]; }

/* opt-int-width: 64/32/16/8 for the integer and char types. */
static int64_t sccp_int_width(int64_t ty) { return sccp_type_width[ty]; }

static int sccp_integer_type(int64_t ty) {
    int64_t klass = sccp_class_of(ty);
    return klass == SCCP_CLASS_SINT || klass == SCCP_CLASS_UINT;
}

static int sccp_int_or_char_type(int64_t ty) {
    int64_t klass = sccp_class_of(ty);
    return klass == SCCP_CLASS_SINT || klass == SCCP_CLASS_UINT ||
           klass == SCCP_CLASS_CHAR;
}

static int sccp_signed_integer_type(int64_t ty) {
    return sccp_class_of(ty) == SCCP_CLASS_SINT;
}

static int sccp_unsigned_integer_type(int64_t ty) {
    return sccp_class_of(ty) == SCCP_CLASS_UINT;
}

static int sccp_bool_type(int64_t ty) {
    return sccp_class_of(ty) == SCCP_CLASS_BOOL;
}

/* opt-normalize-int-to-i64: wrap to the result width, then sign- or
 * zero-extend back to i64. Char is the 8-bit unsigned code unit. */
static int64_t sccp_normalize_int_to_i64(int64_t value, int64_t ty) {
    int64_t klass = sccp_class_of(ty);
    if (klass == SCCP_CLASS_SINT) {
        int64_t width = sccp_int_width(ty);
        if (width == 64) {
            return value;
        }
        return (int64_t)((uint64_t)value << (64 - width)) >> (64 - width);
    }
    if (klass == SCCP_CLASS_UINT) {
        int64_t width = sccp_int_width(ty);
        if (width == 64) {
            return value;
        }
        return value & (((int64_t)1 << width) - 1);
    }
    if (klass == SCCP_CLASS_CHAR) {
        return value & 255;
    }
    return value;
}

/* --- the lattice environment (OptSccpEnv) -------------------------------- */
/* opt-sccp-env-fill-unknown! */
static void sccp_env_fill_unknown(int64_t n, int64_t i) {
    if (i >= n) {
        return;
    }
    /* `(set! (array-ref slots i) (OptSccpValue.Unknown))` stores the tag word
     * only -- the Unknown variant has no payload -- so the mirror writes the
     * tag word only too. A stale payload under an Unknown tag is never read:
     * every reader checks the tag first. */
    sccp_env_slots[i].tag = SCCP_TAG_UNKNOWN;
    sccp_env_fill_unknown(n, i + 1);
}

/* opt-sccp-env-lookup: an out-of-range var reads Unknown, the same default the
 * original assoc list gave for an unbound var. */
static SccpValue sccp_env_lookup(int64_t var) {
    SccpValue unknown;
    if (var >= 0 && var < sccp_env_cap) {
        return sccp_env_slots[var];
    }
    unknown.tag = SCCP_TAG_UNKNOWN;
    unknown.kind = 0;
    unknown.value = 0;
    unknown.ty = 0;
    return unknown;
}

/* The lattice tag alone: 0 Unknown, 1 Const, 2 Overdefined. */
static int64_t sccp_env_tag(int64_t var) {
    if (var >= 0 && var < sccp_env_cap) {
        return sccp_env_slots[var].tag;
    }
    return SCCP_TAG_UNKNOWN;
}

/* The Const payload field `field` (0 kind, 1 value, 2 type). */
static int64_t sccp_env_const_field(int64_t var, int64_t field) {
    if (sccp_env_slots[var].tag != SCCP_TAG_CONST) {
        return 0;
    }
    if (field == 0) {
        return sccp_env_slots[var].kind;
    }
    if (field == 1) {
        return sccp_env_slots[var].value;
    }
    return sccp_env_slots[var].ty;
}

/* opt-sccp-env-set: out-of-range writes are silently dropped. */
static void sccp_env_set(int64_t var, SccpValue value) {
    if (var >= 0 && var < sccp_env_cap) {
        sccp_env_slots[var] = value;
    }
}

/* opt-sccp-env-any-const?: read once at analysis end; when false the whole
 * rewrite is the identity and the caller skips it. */
static int sccp_env_any_const(int64_t index) {
    if (index >= sccp_env_cap) {
        return 0;
    }
    if (sccp_env_tag(index) == SCCP_TAG_CONST) {
        return 1;
    }
    return sccp_env_any_const(index + 1);
}

static int sccp_exec_ref(int64_t id) { return sccp_exec_slots[id] != 0; }

static void sccp_exec_set(int64_t id) { sccp_exec_slots[id] = 1; }

static void sccp_exec_clear(int64_t n) {
    int64_t i;
    for (i = 0; i < n; i += 1) {
        sccp_exec_slots[i] = 0;
    }
}

/* --- value constructors -------------------------------------------------- */
static SccpValue sccp_unknown(void) {
    SccpValue out;
    out.tag = SCCP_TAG_UNKNOWN;
    out.kind = 0;
    out.value = 0;
    out.ty = 0;
    return out;
}

static SccpValue sccp_overdefined(void) {
    SccpValue out;
    out.tag = SCCP_TAG_OVERDEFINED;
    out.kind = 0;
    out.value = 0;
    out.ty = 0;
    return out;
}

static SccpValue sccp_const(int64_t kind, int64_t value, int64_t ty) {
    SccpValue out;
    out.tag = SCCP_TAG_CONST;
    out.kind = kind;
    out.value = value;
    out.ty = ty;
    return out;
}

/* --- opt-sccp-value-eq / opt-sccp-join ----------------------------------- */
static int sccp_value_eq(const SccpValue *a, const SccpValue *b) {
    if (a->tag == SCCP_TAG_UNKNOWN) {
        return b->tag == SCCP_TAG_UNKNOWN;
    }
    if (a->tag == SCCP_TAG_OVERDEFINED) {
        return b->tag == SCCP_TAG_OVERDEFINED;
    }
    if (b->tag != SCCP_TAG_CONST) {
        return 0;
    }
    return a->kind == b->kind && a->value == b->value && a->ty == b->ty;
}

static SccpValue sccp_join(const SccpValue *old, const SccpValue *fresh) {
    if (old->tag == SCCP_TAG_UNKNOWN) {
        if (fresh->tag == SCCP_TAG_UNKNOWN) {
            return sccp_unknown();
        }
        if (fresh->tag == SCCP_TAG_OVERDEFINED) {
            return sccp_overdefined();
        }
        return sccp_const(fresh->kind, fresh->value, fresh->ty);
    }
    if (old->tag == SCCP_TAG_OVERDEFINED) {
        return sccp_overdefined();
    }
    if (fresh->tag == SCCP_TAG_UNKNOWN) {
        return sccp_const(old->kind, old->value, old->ty);
    }
    if (fresh->tag == SCCP_TAG_OVERDEFINED) {
        return sccp_overdefined();
    }
    if (old->kind == fresh->kind && old->value == fresh->value &&
        old->ty == fresh->ty) {
        return sccp_const(old->kind, old->value, old->ty);
    }
    return sccp_overdefined();
}

/* opt-sccp-state-bind: join the incoming value onto the slot; when the join
 * moves the slot, record it and raise the changed flag. */
static void sccp_state_bind(int64_t var, SccpValue value) {
    SccpValue old = sccp_env_lookup(var);
    SccpValue merged = sccp_join(&old, &value);
    if (sccp_value_eq(&old, &merged)) {
        return;
    }
    sccp_env_set(var, merged);
    sccp_changed = 1;
}

/* --- the label index (opt-cfg-index-id) ---------------------------------- */
/* opt-cfg-index-id-map-capacity: the next power of two at or above 2 * count,
 * so a probe that misses always terminates on an empty slot. */
static int64_t sccp_id_map_capacity(int64_t count) {
    int64_t size = 2;
    while (size < count * 2) {
        size *= 2;
    }
    return size;
}

/* opt-cfg-index-id-slot: fold the high bits down, then mask. */
static int64_t sccp_id_slot(int64_t label, int64_t mask) {
    return (label ^ (label >> 5)) & mask;
}

/* opt-cfg-index-fill-id-map!: ids inserted in block order, an occupied slot
 * whose label matches left alone, so a duplicate label resolves to its first
 * block. */
static void sccp_cfg_index_build(void) {
    int64_t cap = sccp_id_map_capacity(sccp_nblocks);
    int64_t mask = cap - 1;
    int64_t i;
    sccp_idmask = mask;
    for (i = 0; i < cap; i += 1) {
        sccp_idmap[i] = 0;
    }
    for (i = 0; i < sccp_nblocks; i += 1) {
        sccp_labels[i] = sccp_tokens[sccp_block_base + i * 5];
    }
    for (i = 0; i < sccp_nblocks; i += 1) {
        int64_t label = sccp_labels[i];
        int64_t slot = sccp_id_slot(label, mask);
        int placed = 0;
        while (!placed) {
            int64_t entry = sccp_idmap[slot];
            if (entry == 0) {
                sccp_idmap[slot] = i + 1;
                placed = 1;
            } else if (sccp_labels[entry - 1] == label) {
                placed = 1;
            } else {
                slot = (slot + 1) & mask;
            }
        }
    }
}

/* opt-cfg-index-id: -1 stands for option_i64.None. */
static int64_t sccp_cfg_index_id(int64_t label) {
    int64_t mask = sccp_idmask;
    int64_t slot = sccp_id_slot(label, mask);
    for (;;) {
        int64_t entry = sccp_idmap[slot];
        if (entry == 0) {
            return -1;
        }
        if (sccp_labels[entry - 1] == label) {
            return entry - 1;
        }
        slot = (slot + 1) & mask;
    }
}

/* opt-sccp-state-mark-executable. */
static void sccp_state_mark_executable(int64_t label) {
    int64_t id = sccp_cfg_index_id(label);
    if (id >= 0 && id < sccp_nblocks) {
        if (!sccp_exec_ref(id)) {
            sccp_exec_set(id);
            sccp_changed = 1;
        }
    }
}

/* --- constants and the folder -------------------------------------------- */
/* opt-normalize-const, with NoConst already mapped to the Overdefined that
 * opt-sccp-immediate turns it into. */
static SccpValue sccp_normalize_const(int64_t kind, int64_t value, int64_t ty) {
    int64_t klass = sccp_class_of(ty);
    if (klass == SCCP_CLASS_SINT || klass == SCCP_CLASS_UINT) {
        if (kind == SCCP_VK_INT) {
            return sccp_const(SCCP_VK_INT,
                              sccp_normalize_int_to_i64(value, ty), ty);
        }
        return sccp_overdefined();
    }
    if (klass == SCCP_CLASS_CHAR) {
        if (kind == SCCP_VK_INT) {
            return sccp_const(SCCP_VK_INT, value & 255, SCCP_TY_CHAR);
        }
        return sccp_overdefined();
    }
    if (klass == SCCP_CLASS_BOOL) {
        if (kind == SCCP_VK_BOOL) {
            return sccp_const(SCCP_VK_BOOL, value, SCCP_TY_BOOL);
        }
        return sccp_overdefined();
    }
    return sccp_overdefined();
}

/* opt-sccp-immediate over opt-default-immediate-type. */
static SccpValue sccp_immediate(int64_t kind, int64_t value, int64_t ty) {
    int64_t fallback;
    if (kind == SCCP_VK_INT) {
        fallback = sccp_int_or_char_type(ty) ? ty : SCCP_TY_I64;
    } else if (kind == SCCP_VK_BOOL) {
        fallback = SCCP_TY_BOOL;
    } else {
        fallback = ty;
    }
    return sccp_normalize_const(kind, value, fallback);
}

/* opt-sccp-value. */
static SccpValue sccp_value(int64_t kind, int64_t payload, int64_t ty) {
    if (kind == SCCP_VK_VAR) {
        return sccp_env_lookup(payload);
    }
    if (kind == SCCP_VK_NONE) {
        return sccp_unknown();
    }
    return sccp_immediate(kind, payload, ty);
}

/* opt-binop-operand-type. */
static int64_t sccp_binop_operand_type(int64_t op, int64_t lhs_ty,
                                       int64_t rhs_ty, int64_t result_ty) {
    if (op == SCCP_OP_EQ || op == SCCP_OP_NE || op == SCCP_OP_LT ||
        op == SCCP_OP_LE || op == SCCP_OP_GT || op == SCCP_OP_GE) {
        if (lhs_ty == SCCP_TY_I64) {
            return rhs_ty;
        }
        if (lhs_ty == SCCP_TY_F64 && rhs_ty == SCCP_TY_F32) {
            return rhs_ty;
        }
        return lhs_ty;
    }
    if (op == SCCP_OP_BIT_AND || op == SCCP_OP_BIT_OR ||
        op == SCCP_OP_BIT_XOR || op == SCCP_OP_SHL || op == SCCP_OP_SHR) {
        return lhs_ty;
    }
    return result_ty;
}

/* opt-unsigned-lt? / opt-typed-lt?: only U64 needs the unsigned comparison;
 * every narrower unsigned value is already zero-extended. */
static int sccp_typed_lt(int64_t a, int64_t b, int64_t ty) {
    if (sccp_unsigned_integer_type(ty) && sccp_int_width(ty) == 64) {
        return (uint64_t)a < (uint64_t)b;
    }
    return a < b;
}

static int sccp_fold_compare(int64_t op, int64_t a, int64_t b, int64_t ty) {
    if (op == SCCP_OP_EQ) {
        return a == b;
    }
    if (op == SCCP_OP_NE) {
        return a != b;
    }
    if (op == SCCP_OP_LT) {
        return sccp_typed_lt(a, b, ty);
    }
    if (op == SCCP_OP_LE) {
        return a == b || sccp_typed_lt(a, b, ty);
    }
    if (op == SCCP_OP_GT) {
        return sccp_typed_lt(b, a, ty);
    }
    return a == b || sccp_typed_lt(b, a, ty);
}

/* opt-signed-min for the divide/remainder refusal. */
static int64_t sccp_signed_min(int64_t ty) {
    int64_t width = sccp_int_width(ty);
    if (width == 64) {
        return -9223372036854775807LL - 1;
    }
    return -((int64_t)1 << (width - 1));
}

/* opt-divmod-valid? */
static int sccp_divmod_valid(int64_t a, int64_t b, int64_t ty) {
    if (b == 0) {
        return 0;
    }
    if (sccp_signed_integer_type(ty)) {
        return !(a == sccp_signed_min(ty) && b == -1);
    }
    return 1;
}

/* opt-fold-div-value / opt-fold-mod-value: the operands arrive normalized to
 * the operand type, so the i64 (signed) or u64 (unsigned) operation is the
 * width-w one. */
static int64_t sccp_fold_div_value(int64_t a, int64_t b, int64_t ty) {
    if (sccp_signed_integer_type(ty)) {
        return a / b;
    }
    return (int64_t)((uint64_t)a / (uint64_t)b);
}

static int64_t sccp_fold_mod_value(int64_t a, int64_t b, int64_t ty) {
    if (sccp_signed_integer_type(ty)) {
        return a % b;
    }
    return (int64_t)((uint64_t)a % (uint64_t)b);
}

/* opt-fold-shr-value: arithmetic for the signed widths, logical otherwise. */
static int64_t sccp_fold_shr_value(int64_t a, int64_t count, int64_t ty) {
    if (sccp_signed_integer_type(ty)) {
        return a >> count;
    }
    return (int64_t)((uint64_t)a >> (uint64_t)count);
}

/* opt-shift-count-valid? */
static int sccp_shift_count_valid(int64_t count, int64_t count_ty,
                                  int64_t width) {
    if (!sccp_integer_type(count_ty)) {
        return 0;
    }
    if (sccp_signed_integer_type(count_ty)) {
        return count >= 0 && count < width;
    }
    if (sccp_int_width(count_ty) == 64) {
        return (uint64_t)count < (uint64_t)width;
    }
    return count < width;
}

/* opt-fold-shift. */
static SccpValue sccp_fold_shift(int64_t op, int64_t a, int64_t rhs_kind,
                                 int64_t rhs_value, int64_t rhs_ty,
                                 int64_t operand_ty, int64_t ty) {
    int64_t count;
    int64_t shifted;
    if (!(sccp_int_or_char_type(rhs_ty) && rhs_kind == SCCP_VK_INT)) {
        return sccp_overdefined();
    }
    count = sccp_normalize_int_to_i64(rhs_value, rhs_ty);
    if (!sccp_shift_count_valid(count, rhs_ty, sccp_int_width(operand_ty))) {
        return sccp_overdefined();
    }
    if (op == SCCP_OP_SHL) {
        shifted = (int64_t)((uint64_t)a << (uint64_t)count);
    } else {
        shifted = sccp_fold_shr_value(a, count, operand_ty);
    }
    return sccp_const(SCCP_VK_INT,
                      sccp_normalize_int_to_i64(shifted, operand_ty), ty);
}

/* opt-fold-bool. */
static SccpValue sccp_fold_bool(int64_t op, int64_t lhs_kind, int64_t lhs_value,
                                int64_t rhs_kind, int64_t rhs_value,
                                int64_t ty) {
    int a;
    int b;
    if (!(lhs_kind == SCCP_VK_BOOL && rhs_kind == SCCP_VK_BOOL)) {
        return sccp_overdefined();
    }
    a = lhs_value != 0;
    b = rhs_value != 0;
    if (op == SCCP_OP_AND) {
        return sccp_const(SCCP_VK_BOOL, (a && b) ? 1 : 0, ty);
    }
    if (op == SCCP_OP_OR) {
        return sccp_const(SCCP_VK_BOOL, (a || b) ? 1 : 0, ty);
    }
    if (op == SCCP_OP_EQ) {
        return sccp_const(SCCP_VK_BOOL, (lhs_value == rhs_value) ? 1 : 0, ty);
    }
    if (op == SCCP_OP_NE) {
        return sccp_const(SCCP_VK_BOOL, (lhs_value == rhs_value) ? 0 : 1, ty);
    }
    return sccp_overdefined();
}

/* opt-fold-int-char-binop's arithmetic arms: every one of these is gated on
 * `opt-integer-type?`, so `char` operands fall through to Overdefined. */
static SccpValue sccp_fold_int_arith(int64_t op, int64_t a, int64_t b,
                                     int64_t operand_ty, int64_t ty) {
    if (!sccp_integer_type(operand_ty)) {
        return sccp_overdefined();
    }
    if (op == SCCP_OP_ADD) {
        return sccp_const(
            SCCP_VK_INT,
            sccp_normalize_int_to_i64((int64_t)((uint64_t)a + (uint64_t)b),
                                      operand_ty),
            ty);
    }
    if (op == SCCP_OP_SUB) {
        return sccp_const(
            SCCP_VK_INT,
            sccp_normalize_int_to_i64((int64_t)((uint64_t)a - (uint64_t)b),
                                      operand_ty),
            ty);
    }
    if (op == SCCP_OP_MUL) {
        return sccp_const(
            SCCP_VK_INT,
            sccp_normalize_int_to_i64((int64_t)((uint64_t)a * (uint64_t)b),
                                      operand_ty),
            ty);
    }
    if (op == SCCP_OP_BIT_AND) {
        return sccp_const(SCCP_VK_INT,
                          sccp_normalize_int_to_i64(a & b, operand_ty), ty);
    }
    if (op == SCCP_OP_BIT_OR) {
        return sccp_const(SCCP_VK_INT,
                          sccp_normalize_int_to_i64(a | b, operand_ty), ty);
    }
    if (op == SCCP_OP_BIT_XOR) {
        return sccp_const(SCCP_VK_INT,
                          sccp_normalize_int_to_i64(a ^ b, operand_ty), ty);
    }
    if (op == SCCP_OP_DIV || op == SCCP_OP_SAFE_DIV) {
        if (sccp_divmod_valid(a, b, operand_ty)) {
            return sccp_const(SCCP_VK_INT, sccp_fold_div_value(a, b, operand_ty),
                              ty);
        }
        return sccp_overdefined();
    }
    if (op == SCCP_OP_MOD || op == SCCP_OP_SAFE_MOD) {
        if (sccp_divmod_valid(a, b, operand_ty)) {
            return sccp_const(SCCP_VK_INT, sccp_fold_mod_value(a, b, operand_ty),
                              ty);
        }
        return sccp_overdefined();
    }
    return sccp_overdefined();
}

/* opt-fold-int-char-binop. */
static SccpValue sccp_fold_int_char_binop(int64_t op, int64_t lhs_kind,
                                          int64_t lhs_value, int64_t rhs_kind,
                                          int64_t rhs_value, int64_t operand_ty,
                                          int64_t rhs_ty, int64_t ty) {
    int64_t a;
    int64_t b;
    if (!(sccp_int_or_char_type(operand_ty) && lhs_kind == SCCP_VK_INT)) {
        return sccp_overdefined();
    }
    a = sccp_normalize_int_to_i64(lhs_value, operand_ty);
    if (op == SCCP_OP_SHL || op == SCCP_OP_SHR) {
        return sccp_fold_shift(op, a, rhs_kind, rhs_value, rhs_ty, operand_ty,
                               ty);
    }
    if (rhs_kind != SCCP_VK_INT) {
        return sccp_overdefined();
    }
    b = sccp_normalize_int_to_i64(rhs_value, operand_ty);
    if (op == SCCP_OP_EQ || op == SCCP_OP_NE || op == SCCP_OP_LT ||
        op == SCCP_OP_LE || op == SCCP_OP_GT || op == SCCP_OP_GE) {
        return sccp_const(SCCP_VK_BOOL,
                          sccp_fold_compare(op, a, b, operand_ty) ? 1 : 0, ty);
    }
    if (op == SCCP_OP_BIT_TEST_EQ) {
        return sccp_const(SCCP_VK_BOOL, ((a & b) == 0) ? 1 : 0, ty);
    }
    if (op == SCCP_OP_BIT_TEST_NE) {
        return sccp_const(SCCP_VK_BOOL, ((a & b) == 0) ? 0 : 1, ty);
    }
    return sccp_fold_int_arith(op, a, b, operand_ty, ty);
}

/* opt-fold-binop. Float operand types reach the Overdefined arm. */
static SccpValue sccp_fold_binop(int64_t op, int64_t lhs_kind,
                                 int64_t lhs_value, int64_t lhs_ty,
                                 int64_t rhs_kind, int64_t rhs_value,
                                 int64_t rhs_ty, int64_t ty,
                                 int64_t rhs_ty_field) {
    int64_t operand_ty =
        sccp_binop_operand_type(op, lhs_ty, rhs_ty, ty);
    if (sccp_bool_type(operand_ty)) {
        return sccp_fold_bool(op, lhs_kind, lhs_value, rhs_kind, rhs_value, ty);
    }
    if (sccp_int_or_char_type(operand_ty)) {
        return sccp_fold_int_char_binop(op, lhs_kind, lhs_value, rhs_kind,
                                        rhs_value, operand_ty, rhs_ty_field,
                                        ty);
    }
    return sccp_overdefined();
}

/* opt-sccp-fold-binop-value. */
static SccpValue sccp_fold_binop_value(int64_t op, const SccpValue *lhs,
                                       const SccpValue *rhs, int64_t ty,
                                       int64_t rhs_ty_field) {
    if (lhs->tag == SCCP_TAG_CONST) {
        if (rhs->tag == SCCP_TAG_CONST) {
            return sccp_fold_binop(op, lhs->kind, lhs->value, lhs->ty,
                                   rhs->kind, rhs->value, rhs->ty, ty,
                                   rhs_ty_field);
        }
        if (rhs->tag == SCCP_TAG_UNKNOWN) {
            return sccp_unknown();
        }
        return sccp_overdefined();
    }
    if (lhs->tag == SCCP_TAG_UNKNOWN) {
        return sccp_unknown();
    }
    return sccp_overdefined();
}

/* opt-fold-unop. */
static SccpValue sccp_fold_unop(int64_t op, int64_t kind, int64_t value,
                                int64_t ty) {
    if (op == SCCP_OP_NEG) {
        if (sccp_integer_type(ty) && kind == SCCP_VK_INT) {
            int64_t a = sccp_normalize_int_to_i64(value, ty);
            return sccp_const(
                SCCP_VK_INT,
                sccp_normalize_int_to_i64((int64_t)(0 - (uint64_t)a), ty), ty);
        }
        return sccp_overdefined();
    }
    if (op == SCCP_OP_NOT) {
        if (sccp_bool_type(ty) && kind == SCCP_VK_BOOL) {
            return sccp_const(SCCP_VK_BOOL, (value == 0) ? 1 : 0, ty);
        }
        return sccp_overdefined();
    }
    if (op == SCCP_OP_BITNOT) {
        if (sccp_integer_type(ty) && kind == SCCP_VK_INT) {
            int64_t a = sccp_normalize_int_to_i64(value, ty);
            return sccp_const(SCCP_VK_INT,
                              sccp_normalize_int_to_i64(~a, ty), ty);
        }
        return sccp_overdefined();
    }
    return sccp_overdefined();
}

/* opt-sccp-fold-unop-value. */
static SccpValue sccp_fold_unop_value(int64_t op, const SccpValue *src,
                                      int64_t ty) {
    if (src->tag == SCCP_TAG_CONST) {
        return sccp_fold_unop(op, src->kind, src->value, ty);
    }
    if (src->tag == SCCP_TAG_UNKNOWN) {
        return sccp_unknown();
    }
    return sccp_overdefined();
}

/* opt-fold-cast over compiler-finite-cast-fold's integer arms. */
static SccpValue sccp_fold_cast(int64_t kind, int64_t value, int64_t from_ty,
                                int64_t to_ty) {
    if (!(sccp_int_or_char_type(from_ty) && kind == SCCP_VK_INT)) {
        return sccp_overdefined();
    }
    if (!sccp_int_or_char_type(to_ty)) {
        return sccp_overdefined();
    }
    return sccp_const(
        SCCP_VK_INT,
        sccp_normalize_int_to_i64(sccp_normalize_int_to_i64(value, from_ty),
                                  to_ty),
        to_ty);
}

/* opt-sccp-fold-cast-value. */
static SccpValue sccp_fold_cast_value(const SccpValue *src, int64_t from_ty,
                                      int64_t to_ty) {
    if (src->tag == SCCP_TAG_CONST) {
        return sccp_fold_cast(src->kind, src->value, from_ty, to_ty);
    }
    if (src->tag == SCCP_TAG_UNKNOWN) {
        return sccp_unknown();
    }
    return sccp_overdefined();
}

/* --- phis ---------------------------------------------------------------- */
/* opt-sccp-phi-input-value: an input from a predecessor that is not executable
 * contributes Unknown. */
static SccpValue sccp_phi_input_value(int64_t pred, int64_t kind, int64_t value,
                                      int64_t ty) {
    int64_t id = sccp_cfg_index_id(pred);
    if (id >= 0 && id < sccp_nblocks && sccp_exec_ref(id)) {
        return sccp_value(kind, value, ty);
    }
    return sccp_unknown();
}

/* opt-sccp-phi-value: join(first, phi-value(rest)), Unknown at the end. */
static SccpValue sccp_phi_value(int64_t base, int64_t count, int64_t ty) {
    int64_t at;
    SccpValue head;
    SccpValue rest;
    if (count <= 0) {
        return sccp_unknown();
    }
    at = sccp_phi_base + base * 3;
    head = sccp_phi_input_value(sccp_tokens[at], sccp_tokens[at + 1],
                                sccp_tokens[at + 2], ty);
    rest = sccp_phi_value(base + 1, count - 1, ty);
    return sccp_join(&head, &rest);
}

/* --- terminators --------------------------------------------------------- */
/* opt-sccp-mark-branch-targets: a Const bool marks only the taken successor, a
 * Const of any other shape and Overdefined mark both, Unknown marks none. */
static void sccp_mark_branch_targets(int64_t kind, int64_t payload,
                                     int64_t true_label, int64_t false_label) {
    SccpValue cond = sccp_value(kind, payload, SCCP_TY_BOOL);
    if (cond.tag == SCCP_TAG_CONST) {
        if (cond.kind == SCCP_VK_BOOL) {
            if (cond.value == 0) {
                sccp_state_mark_executable(false_label);
            } else {
                sccp_state_mark_executable(true_label);
            }
        } else {
            sccp_state_mark_executable(true_label);
            sccp_state_mark_executable(false_label);
        }
        return;
    }
    if (cond.tag == SCCP_TAG_OVERDEFINED) {
        sccp_state_mark_executable(true_label);
        sccp_state_mark_executable(false_label);
    }
}

/* opt-sccp-mark-switch-targets, over the block's successor row (index 0 is the
 * default label, which opt-sccp-process-instr marks first). */
static void sccp_mark_switch_targets(int64_t base, int64_t count) {
    int64_t index;
    for (index = 0; index < count; index += 1) {
        sccp_state_mark_executable(sccp_tokens[sccp_succ_base + base + index]);
    }
}

/* --- the per-instruction dispatch (opt-sccp-process-instr) --------------- */
static void sccp_process_instr(int64_t succ_base, int64_t succ_count,
                               int64_t row) {
    int64_t at = sccp_instr_base + row * 8;
    int64_t op = sccp_tokens[at];
    int64_t dst = sccp_tokens[at + 1];
    int64_t ty = sccp_tokens[at + 2];
    int64_t ty2 = sccp_tokens[at + 3];
    int64_t a = sccp_tokens[at + 4];
    int64_t akind = sccp_tokens[at + 5];
    int64_t b = sccp_tokens[at + 6];
    int64_t bkind = sccp_tokens[at + 7];
    if (op == SCCP_OP_MOV) {
        sccp_state_bind(dst, sccp_value(akind, a, ty));
    } else if (op == SCCP_OP_OVERDEF) {
        sccp_state_bind(dst, sccp_overdefined());
    } else if (op == SCCP_OP_CAST) {
        SccpValue src = sccp_value(akind, a, ty2);
        sccp_state_bind(dst, sccp_fold_cast_value(&src, ty2, ty));
    } else if (op == SCCP_OP_PHI) {
        sccp_state_bind(dst, sccp_phi_value(a, b, ty));
    } else if (op == SCCP_OP_JUMP) {
        sccp_state_mark_executable(sccp_tokens[sccp_succ_base + succ_base]);
    } else if (op == SCCP_OP_BRANCH) {
        sccp_mark_branch_targets(akind, a,
                                 sccp_tokens[sccp_succ_base + succ_base],
                                 sccp_tokens[sccp_succ_base + succ_base + 1]);
    } else if (op == SCCP_OP_SWITCH) {
        sccp_mark_switch_targets(succ_base, succ_count);
    } else if (op == SCCP_OP_OTHER || op == SCCP_OP_BOUNDS) {
        return;
    } else if (op == SCCP_OP_NEG || op == SCCP_OP_NOT || op == SCCP_OP_BITNOT ||
               op == SCCP_OP_SQRT) {
        SccpValue src = sccp_value(akind, a, ty);
        sccp_state_bind(dst, sccp_fold_unop_value(op, &src, ty));
    } else {
        SccpValue lhs = sccp_value(akind, a, ty);
        SccpValue rhs = sccp_value(bkind, b, ty2);
        sccp_state_bind(dst, sccp_fold_binop_value(op, &lhs, &rhs, ty, ty2));
    }
}

/* opt-sccp-process-instr-seq-from. */
static void sccp_process_instr_seq_from(int64_t succ_base, int64_t succ_count,
                                        int64_t row, int64_t last) {
    if (row >= last) {
        return;
    }
    sccp_process_instr(succ_base, succ_count, row);
    sccp_process_instr_seq_from(succ_base, succ_count, row + 1, last);
}

/* opt-sccp-process-block: only executable blocks are walked. */
static void sccp_process_block(int64_t block) {
    int64_t at;
    int64_t succ_base;
    int64_t succ_count;
    int64_t first;
    int64_t count;
    if (!sccp_exec_ref(block)) {
        return;
    }
    at = sccp_block_base + block * 5;
    succ_base = sccp_tokens[at + 1];
    succ_count = sccp_tokens[at + 2];
    first = sccp_tokens[at + 3];
    count = sccp_tokens[at + 4];
    sccp_process_instr_seq_from(succ_base, succ_count, first, first + count);
}

/* opt-sccp-process-blocks-from. */
static void sccp_process_blocks_from(int64_t block) {
    if (block >= sccp_nblocks) {
        return;
    }
    sccp_process_block(block);
    sccp_process_blocks_from(block + 1);
}

/* opt-sccp-analyze-fixed: sweep while something changed, bounded by
 * nblocks + 8 + 2 * ninstr. */
static void sccp_analyze_fixed(int64_t remaining) {
    if (remaining <= 0) {
        return;
    }
    sccp_changed = 0;
    sccp_sweeps += 1;
    sccp_process_blocks_from(0);
    if (sccp_changed) {
        sccp_analyze_fixed(remaining - 1);
    }
}

/* opt-sccp-env-from-params-at: every parameter starts Overdefined. */
static void sccp_env_from_params_at(int64_t position) {
    if (position >= sccp_nparams) {
        return;
    }
    sccp_env_set(sccp_tokens[sccp_param_base + position * 2],
                 sccp_overdefined());
    sccp_env_from_params_at(position + 1);
}

/* --- the counted rewrite ------------------------------------------------- */
/* opt-sccp-rewrite-value: a Var operand whose lattice slot is Const is
 * substituted; the kernel counts the substitution instead of building IR. */
static int sccp_rewrite_substitutes(int64_t kind, int64_t payload) {
    if (kind == SCCP_VK_VAR) {
        return sccp_env_tag(payload) == SCCP_TAG_CONST;
    }
    return 0;
}

/* opt-sccp-instr-changes-successors?: the rewritten condition is a Bool
 * literal, so the branch becomes a jump. */
static int sccp_instr_changes_successors(int64_t kind, int64_t payload) {
    if (kind == SCCP_VK_BOOL) {
        return 1;
    }
    if (kind == SCCP_VK_VAR) {
        if (sccp_env_tag(payload) == SCCP_TAG_CONST) {
            return sccp_env_const_field(payload, 0) == SCCP_VK_BOOL;
        }
        return 0;
    }
    return 0;
}

/* The i64 a rewritten bounds-check operand ends up being, or a sentinel. */
static int64_t sccp_rewritten_i64(int64_t kind, int64_t payload, int64_t miss) {
    if (kind == SCCP_VK_INT) {
        return payload;
    }
    if (kind == SCCP_VK_VAR) {
        if (sccp_env_tag(payload) == SCCP_TAG_CONST) {
            if (sccp_env_const_field(payload, 0) == SCCP_VK_INT &&
                sccp_integer_type(sccp_env_const_field(payload, 2))) {
                return sccp_env_const_field(payload, 1);
            }
            return miss;
        }
        return miss;
    }
    return miss;
}

/* opt-sccp-bounds-check-in-range?: only the in-range case is dropped, so an
 * out-of-range literal keeps its check and still traps. */
static int sccp_bounds_check_in_range(int64_t akind, int64_t a, int64_t bkind,
                                      int64_t b) {
    int64_t index = sccp_rewritten_i64(akind, a, -1);
    int64_t length = sccp_rewritten_i64(bkind, b, -1);
    return index >= 0 && length >= 0 && index < length;
}

static void sccp_rewrite_phi(int64_t base, int64_t count) {
    int64_t index;
    for (index = 0; index < count; index += 1) {
        int64_t at = sccp_phi_base + (base + index) * 3;
        if (sccp_rewrite_substitutes(sccp_tokens[at + 1], sccp_tokens[at + 2])) {
            sccp_subs += 1;
        }
    }
}

/* opt-sccp-rewrite-blocks / -rewrite-instr-seq / -blocks-change-successors?,
 * counted rather than materialised: every block is walked, executable or not. */
static void sccp_rewrite_rows(int64_t row) {
    int64_t at;
    int64_t op;
    int64_t a;
    int64_t akind;
    int64_t b;
    int64_t bkind;
    if (row >= sccp_ninstr) {
        return;
    }
    at = sccp_instr_base + row * 8;
    op = sccp_tokens[at];
    a = sccp_tokens[at + 4];
    akind = sccp_tokens[at + 5];
    b = sccp_tokens[at + 6];
    bkind = sccp_tokens[at + 7];
    if (op == SCCP_OP_PHI) {
        sccp_rewrite_phi(a, b);
    } else {
        if (sccp_rewrite_substitutes(akind, a)) {
            sccp_subs += 1;
        }
        if (sccp_rewrite_substitutes(bkind, b)) {
            sccp_subs += 1;
        }
        if (op == SCCP_OP_BRANCH) {
            if (sccp_instr_changes_successors(akind, a)) {
                sccp_branches += 1;
            }
        } else if (op == SCCP_OP_BOUNDS) {
            if (sccp_bounds_check_in_range(akind, a, bkind, b)) {
                sccp_dropped += 1;
            }
        }
    }
    sccp_rewrite_rows(row + 1);
}

/* --- one function -------------------------------------------------------- */
/* opt-sccp-blocks-with-context-result-raw: build the label index, seed the
 * state, run the fixpoint, then rewrite only when the lattice holds a Const. */
static uint64_t sccp_function(void) {
    uint64_t hash = SCCP_HASH_BASIS;
    int64_t consts = 0;
    int64_t dead = 0;
    int64_t sweeps_before = sccp_sweeps;
    int64_t i;
    sccp_cfg_index_build();
    sccp_env_cap = sccp_frame;
    sccp_env_fill_unknown(sccp_frame, 0);
    sccp_exec_clear(sccp_nblocks);
    sccp_env_from_params_at(0);
    if (sccp_nblocks > 0) {
        sccp_exec_set(0);
    }
    sccp_changed = 1;
    sccp_analyze_fixed(sccp_nblocks + 8 + 2 * sccp_ninstr);
    for (i = 0; i < sccp_frame; i += 1) {
        if (sccp_env_tag(i) == SCCP_TAG_CONST) {
            consts += 1;
            hash = sccp_mix(hash, i);
            hash = sccp_mix(hash, sccp_env_const_field(i, 0));
            hash = sccp_mix(hash, sccp_env_const_field(i, 1));
            hash = sccp_mix(hash, sccp_env_const_field(i, 2));
        }
    }
    for (i = 0; i < sccp_nblocks; i += 1) {
        if (!sccp_exec_ref(i)) {
            dead += 1;
        }
        hash = sccp_mix(hash, sccp_exec_ref(i) ? 1 : 0);
    }
    sccp_consts += consts;
    sccp_dead += dead;
    if (sccp_env_any_const(0)) {
        sccp_rewrite_rows(0);
    }
    hash = sccp_mix(hash, consts);
    hash = sccp_mix(hash, dead);
    hash = sccp_mix(hash, sccp_sweeps - sweeps_before);
    hash = sccp_mix(hash, sccp_subs);
    hash = sccp_mix(hash, sccp_branches);
    return sccp_mix(hash, sccp_dropped);
}

static int64_t sccp_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = sccp_read_file(path, &length);
    int64_t capacity = length / 2 + 8;
    int64_t ntypes;
    int64_t functions;
    int64_t cursor;
    int64_t expect_base;
    int64_t max_frame = 1;
    int64_t max_blocks = 1;
    int64_t max_idmap;
    int64_t round = 0;
    int64_t start = 0;
    int64_t t;
    int64_t f;
    uint64_t acc = SCCP_HASH_BASIS;

    sccp_tokens = sccp_alloc(capacity);
    acc = sccp_mix(acc, sccp_scan_ints(text, length, sccp_tokens));
    ntypes = sccp_tokens[0];
    sccp_type_class = sccp_alloc(ntypes + 1);
    sccp_type_width = sccp_alloc(ntypes + 1);
    for (t = 0; t < ntypes; t += 1) {
        sccp_type_class[t] = sccp_tokens[1 + t * 2];
        sccp_type_width[t] = sccp_tokens[2 + t * 2];
    }
    expect_base = 1 + ntypes * 2;
    cursor = expect_base + 5;
    functions = sccp_tokens[cursor];
    cursor += 1;
    sccp_offsets = sccp_alloc(functions + 1);
    for (f = 0; f < functions; f += 1) {
        int64_t frame = sccp_tokens[cursor];
        int64_t nparams = sccp_tokens[cursor + 1];
        int64_t nblocks = sccp_tokens[cursor + 2];
        int64_t nsucc = sccp_tokens[cursor + 3];
        int64_t nphi = sccp_tokens[cursor + 4];
        int64_t ninstr = sccp_tokens[cursor + 5];
        sccp_offsets[f] = cursor;
        if (frame > max_frame) {
            max_frame = frame;
        }
        if (nblocks > max_blocks) {
            max_blocks = nblocks;
        }
        cursor += 6 + nparams * 2 + nsucc + nphi * 3 + nblocks * 5 + ninstr * 8;
    }
    max_idmap = sccp_id_map_capacity(max_blocks);
    sccp_env_slots =
        (SccpValue *)calloc((size_t)max_frame + 1, sizeof(SccpValue));
    sccp_exec_slots =
        (unsigned char *)calloc((size_t)max_blocks + 1, sizeof(unsigned char));
    if (!sccp_env_slots || !sccp_exec_slots) {
        abort();
    }
    sccp_env_cap = max_frame;
    sccp_labels = sccp_alloc(max_blocks + 1);
    sccp_idmap = sccp_alloc(max_idmap + 1);

    while (round < rounds) {
        int64_t step = 0;
        acc = sccp_mix(acc, round);
        while (step < functions) {
            int64_t index = start + step;
            int64_t offset;
            if (index >= functions) {
                index -= functions;
            }
            offset = sccp_offsets[index];
            sccp_frame = sccp_tokens[offset];
            sccp_nparams = sccp_tokens[offset + 1];
            sccp_nblocks = sccp_tokens[offset + 2];
            sccp_ninstr = sccp_tokens[offset + 5];
            sccp_param_base = offset + 6;
            sccp_succ_base = sccp_param_base + sccp_nparams * 2;
            sccp_phi_base = sccp_succ_base + sccp_tokens[offset + 3];
            sccp_block_base = sccp_phi_base + sccp_tokens[offset + 4] * 3;
            sccp_instr_base = sccp_block_base + sccp_nblocks * 5;
            acc = sccp_mix(acc, (int64_t)sccp_function());
            step += 1;
        }
        start += 1;
        if (start >= functions) {
            start = 0;
        }
        round += 1;
    }
    acc = sccp_mix(acc, sccp_consts);
    acc = sccp_mix(acc, sccp_dead);
    acc = sccp_mix(acc, sccp_subs);
    acc = sccp_mix(acc, sccp_branches);
    acc = sccp_mix(acc, sccp_dropped);
    if (!(sccp_consts == sccp_tokens[expect_base] * rounds &&
          sccp_dead == sccp_tokens[expect_base + 1] * rounds &&
          sccp_subs == sccp_tokens[expect_base + 2] * rounds &&
          sccp_branches == sccp_tokens[expect_base + 3] * rounds &&
          sccp_dropped == sccp_tokens[expect_base + 4] * rounds)) {
        sccp_self_check_ok = 0;
    }
    free(text);
    return (int64_t)acc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)sccp_bench(path, rounds));
    return sccp_self_check_ok ? 0 : 1;
}
