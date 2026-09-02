/* benchmarks/read_sexpr/baseline.c - clang C baseline for read_sexpr.
 *
 * Equivalent to benchmarks/read_sexpr/bench.tl: the TypeLisp compiler's own
 * s-expression reader, the mutually recursive `form-result` /
 * `list-result-with-close` descent that turns the lexer's token array into
 * `Sexpr` trees stored in a dense node pool (a list's children are one
 * contiguous id range, not a cons spine), followed by the recursive
 * `sexpr-view` walk a parser performs over the result. It runs over the real
 * token stream src/lex.tl produces for four compiler modules (see README.md).
 *
 * Mirrored compiler functions, all in src/read.tl unless noted:
 *   form-result                -- dispatch on the token tag
 *   list-result-with-close     -- the RECURSIVE element loop
 *   list-result / bracket-list-result -- pool mark, fresh builder, error path
 *   prefix-tag? / prefix-symbol / prefix-form -- the two-element wrapper
 *   sexpr-builder-new / -push / -grow! / sexpr-list-from-builder /
 *     sexpr-builder-discard!   -- the builder stack
 *   sexpr-node-push / sexpr-node-pool-grow! / -truncate! / -reset! / -len /
 *     sexpr-node-get           -- the node pool, 1024 then doubling
 *   result / read              -- reset the pool, read ONE top-level form
 *   sexpr-view                 -- the Cons / Nil traversal step
 *   ci.intern-syntax-id-from-renderable (src/compiler_intern.tl)
 *   parse-ast-program-forms-into-vec (src/compiler_parse_core.tl) -- the
 *     loader's per-top-level-form drive over a whole file
 *
 * The recursion is real on both sides: `form_result` and
 * `list_result_with_close` call each other, and `sexpr_walk` recurses over
 * `sexpr_view` rather than stepping an explicit stack. The `Sexpr` enum is a
 * tagged struct array here and a `defenum Sexpr` in `(__tl_dyn-array Sexpr)`
 * there; `SexprView` and `ResultSexpr` overlay their payloads the way the
 * TypeLisp enums do.
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

#define RS_HASH_BASIS 1469598103934665603ULL
#define RS_HASH_PRIME 1099511628211ULL

/* src/token.tl token-kind tags. */
#define TAG_LPAREN 1
#define TAG_RPAREN 2
#define TAG_INT 3
#define TAG_SYM 4
#define TAG_END 5
#define TAG_STR 6
#define TAG_CHAR 7
#define TAG_FLOAT 8
#define TAG_LBRACKET 9
#define TAG_RBRACKET 10
#define TAG_QUOTE 11
#define TAG_BACKTICK 12
#define TAG_COMMA 13
#define TAG_COMMA_AT 14

/* src/read.tl Sexpr variants. */
#define SEXPR_INT 0
#define SEXPR_SYM 1
#define SEXPR_LIST 2
#define SEXPR_STR 3
#define SEXPR_CHAR 4
#define SEXPR_FLOAT 5

/* src/read.tl SexprView variants. */
#define VIEW_INT 0
#define VIEW_SYM 1
#define VIEW_NIL 2
#define VIEW_CONS 3
#define VIEW_STR 4
#define VIEW_CHAR 5
#define VIEW_FLOAT 6

#define RESULT_OK 0
#define RESULT_ERR 1

#define ERR_UNEXPECTED_RPAREN 1
#define ERR_UNEXPECTED_RBRACKET 2
#define ERR_UNEXPECTED_END 3
#define ERR_UNTERMINATED_PAREN 4
#define ERR_UNTERMINATED_BRACKET 5

/* The four `stable-symbol-id` literals `prefix-symbol` names; the compiler
 * interns them once and memoizes them, so their ids never depend on the input.
 * Four sentinels above the corpus id space keep them distinct here. */
#define SYM_QUOTE 1000000001
#define SYM_QUASIQUOTE 1000000002
#define SYM_UNQUOTE 1000000003
#define SYM_UNQUOTE_SPLICING 1000000004

/* The values tools/export_tokens.py computes by replaying the same descent
 * over data/tokens.txt. */
#define EXPECT_FORMS 3002
#define EXPECT_NODES 270063

typedef struct {
    int64_t tag;
    int64_t payload;
} Token;

/* `defenum Sexpr`: a tag plus the widest payload, two i64 (List start len). */
typedef struct {
    int64_t tag;
    int64_t a;
    int64_t b;
} Sexpr;

/* `defenum SexprView`: a tag plus the widest payload, Cons's two Sexpr. Atom
 * views put their single payload in `head.a`, the way the TypeLisp enum's
 * variants overlay one another. */
typedef struct {
    int64_t tag;
    Sexpr head;
    Sexpr tail;
} SexprView;

/* `defenum ResultSexpr`: Ok Sexpr | Err i64; the error code overlays form.a. */
typedef struct {
    int64_t tag;
    Sexpr form;
} ResultSexpr;

typedef struct {
    int64_t start;
} SexprBuilder;

/* The node pool and the builder stack: two plain globals each (array + count),
 * NOT a struct, exactly as src/read.tl declares them. Storage is retained
 * across resets and never shrinks. */
static Sexpr *sexpr_node_pool_slots;
static int64_t sexpr_node_pool_cap;
static int64_t sexpr_node_pool_count;
static Sexpr *sexpr_builder_slots;
static int64_t sexpr_builder_cap;
static int64_t sexpr_builder_count;

/* The token stream and the reader's one-element cursor cell, which src/read.tl
 * threads through the descent as a `(&mut cur (__tl_dyn-array i64))`. */
static Token *rs_toks;
static int64_t rs_cur[1];

/* Consumer-walk accumulators, folded into the checksum once per pass. */
static int64_t rs_walk_nodes;
static int64_t rs_walk_depth;

/* Per-pass self-check counters. */
static int64_t rs_forms;
static int64_t rs_nodes;

static uint64_t rs_mix(uint64_t hash, int64_t value) {
    return (hash ^ (uint64_t)value) * RS_HASH_PRIME;
}

static int64_t *rs_alloc_i64(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static char *rs_read_file(const char *path, int64_t *length) {
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

static int64_t rs_byte_at(const char *text, int64_t n, int64_t i) {
    return i < n ? (int64_t)(unsigned char)text[i] : -1;
}

static int rs_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t rs_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = rs_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && rs_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (rs_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (rs_digit(rs_byte_at(text, n, i))) {
                value = value * 10 + (rs_byte_at(text, n, i) - 48);
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

/* ------------------------------------------------------------------------ */
/* Dense s-expression node storage (src/read.tl).                            */
/* ------------------------------------------------------------------------ */

static Sexpr sexpr_make(int64_t tag, int64_t a, int64_t b) {
    Sexpr node;
    node.tag = tag;
    node.a = a;
    node.b = b;
    return node;
}

static int64_t sexpr_node_pool_len(void) { return sexpr_node_pool_count; }

/* Grow is a safety net: the pool is reset per top-level form, so it settles at
 * the largest form's node count and never grows again. */
static void sexpr_node_pool_grow(void) {
    int64_t old_cap = sexpr_node_pool_cap;
    int64_t new_cap = old_cap < 1 ? 1024 : old_cap * 2;
    Sexpr *new_slots = (Sexpr *)calloc((size_t)new_cap, sizeof(Sexpr));
    int64_t len = sexpr_node_pool_count;
    int64_t i = 0;
    if (!new_slots) {
        abort();
    }
    while (i < len) {
        new_slots[i] = sexpr_node_pool_slots[i];
        i += 1;
    }
    free(sexpr_node_pool_slots);
    sexpr_node_pool_slots = new_slots;
    sexpr_node_pool_cap = new_cap;
}

static void sexpr_builder_grow(void) {
    int64_t old_cap = sexpr_builder_cap;
    int64_t new_cap = old_cap < 1 ? 1024 : old_cap * 2;
    Sexpr *new_slots = (Sexpr *)calloc((size_t)new_cap, sizeof(Sexpr));
    int64_t i = 0;
    if (!new_slots) {
        abort();
    }
    while (i < sexpr_builder_count) {
        new_slots[i] = sexpr_builder_slots[i];
        i += 1;
    }
    free(sexpr_builder_slots);
    sexpr_builder_slots = new_slots;
    sexpr_builder_cap = new_cap;
}

static int64_t sexpr_node_push(Sexpr node) {
    int64_t id;
    if (sexpr_node_pool_count >= sexpr_node_pool_cap) {
        sexpr_node_pool_grow();
    }
    id = sexpr_node_pool_count;
    sexpr_node_pool_slots[id] = node;
    sexpr_node_pool_count = id + 1;
    return id;
}

static Sexpr sexpr_node_get(int64_t id) { return sexpr_node_pool_slots[id]; }

static Sexpr sexpr_builder_get(int64_t id) { return sexpr_builder_slots[id]; }

static void sexpr_node_pool_truncate(int64_t mark) {
    sexpr_node_pool_count = mark;
}

static void sexpr_node_pool_reset(void) {
    sexpr_node_pool_truncate(0);
    sexpr_builder_count = 0;
}

static SexprBuilder sexpr_builder_new(void) {
    SexprBuilder builder;
    builder.start = sexpr_builder_count;
    return builder;
}

static SexprBuilder sexpr_builder_push(SexprBuilder builder, Sexpr item) {
    if (sexpr_builder_count >= sexpr_builder_cap) {
        sexpr_builder_grow();
    }
    sexpr_builder_slots[sexpr_builder_count] = item;
    sexpr_builder_count += 1;
    return builder;
}

static Sexpr sexpr_list_from_builder(SexprBuilder builder) {
    int64_t start = sexpr_node_pool_len();
    int64_t builder_start = builder.start;
    int64_t len = sexpr_builder_count - builder_start;
    int64_t i = 0;
    while (i < len) {
        sexpr_node_push(sexpr_builder_get(builder_start + i));
        i += 1;
    }
    sexpr_builder_count = builder_start;
    return sexpr_make(SEXPR_LIST, start, len);
}

static void sexpr_builder_discard(SexprBuilder builder) {
    sexpr_builder_count = builder.start;
}

/* An atom view writes only its tag and its one payload word, the way the
 * TypeLisp enum constructor writes only the variant's own fields; the wider
 * Cons payload the union reserves is left alone and never read. */
static SexprView sexpr_view_atom(int64_t tag, int64_t value) {
    SexprView view;
    view.tag = tag;
    view.head.a = value;
    return view;
}

static SexprView sexpr_view(Sexpr s) {
    switch (s.tag) {
    case SEXPR_INT:
        return sexpr_view_atom(VIEW_INT, s.a);
    case SEXPR_SYM:
        return sexpr_view_atom(VIEW_SYM, s.a);
    case SEXPR_LIST:
        if (s.b <= 0) {
            return sexpr_view_atom(VIEW_NIL, 0);
        } else {
            SexprView view;
            view.tag = VIEW_CONS;
            view.head = sexpr_node_get(s.a);
            view.tail = sexpr_make(SEXPR_LIST, s.a + 1, s.b - 1);
            return view;
        }
    case SEXPR_STR:
        return sexpr_view_atom(VIEW_STR, s.a);
    case SEXPR_CHAR:
        return sexpr_view_atom(VIEW_CHAR, s.a);
    default:
        return sexpr_view_atom(VIEW_FLOAT, s.a);
    }
}

/* ------------------------------------------------------------------------ */
/* Cursor helpers (src/read.tl).                                             */
/* ------------------------------------------------------------------------ */

static int64_t cur_pos(const int64_t *cur) { return cur[0]; }

static int64_t peek_tag(const Token *toks, const int64_t *cur) {
    return toks[cur_pos(cur)].tag;
}

/* Consume the current token: advance the cursor by one. */
static void advance(int64_t *cur) { cur[0] = cur_pos(cur) + 1; }

static int prefix_tag(int64_t t) {
    return t == TAG_QUOTE || t == TAG_BACKTICK || t == TAG_COMMA ||
           t == TAG_COMMA_AT;
}

static int64_t prefix_symbol(int64_t t) {
    if (t == TAG_QUOTE) {
        return SYM_QUOTE;
    }
    if (t == TAG_BACKTICK) {
        return SYM_QUASIQUOTE;
    }
    if (t == TAG_COMMA) {
        return SYM_UNQUOTE;
    }
    if (t == TAG_COMMA_AT) {
        return SYM_UNQUOTE_SPLICING;
    }
    return SYM_QUOTE;
}

static Sexpr prefix_form(int64_t name, Sexpr form) {
    return sexpr_list_from_builder(sexpr_builder_push(
        sexpr_builder_push(sexpr_builder_new(), sexpr_make(SEXPR_SYM, name, 0)),
        form));
}

/* ci.intern-syntax-id-from-renderable: `InternId` stores a u32 and
 * `InternSyntaxId` a u64, so the transform every `Sexpr.Sym` payload passes
 * through is the id truncated to 32 bits and widened again. */
static int64_t intern_syntax_id_from_renderable(int64_t id) {
    return id & 4294967295;
}

/* ------------------------------------------------------------------------ */
/* The recursive descent.                                                    */
/* ------------------------------------------------------------------------ */

static ResultSexpr result_ok(Sexpr form) {
    ResultSexpr result;
    result.tag = RESULT_OK;
    result.form = form;
    return result;
}

static ResultSexpr result_err(int64_t code) {
    ResultSexpr result;
    result.tag = RESULT_ERR;
    result.form.a = code;
    return result;
}

static ResultSexpr list_result(const Token *toks, int64_t *cur);
static ResultSexpr bracket_list_result(const Token *toks, int64_t *cur);

static ResultSexpr form_result(const Token *toks, int64_t *cur) {
    const Token *tok = &toks[cur_pos(cur)];
    int64_t t = peek_tag(toks, cur);
    if (t == TAG_INT) {
        advance(cur);
        return result_ok(sexpr_make(SEXPR_INT, tok->payload, 0));
    }
    if (t == TAG_FLOAT) {
        advance(cur);
        return result_ok(sexpr_make(SEXPR_FLOAT, tok->payload, 0));
    }
    if (t == TAG_SYM) {
        advance(cur);
        return result_ok(sexpr_make(
            SEXPR_SYM, intern_syntax_id_from_renderable(tok->payload), 0));
    }
    if (t == TAG_STR) {
        advance(cur);
        return result_ok(sexpr_make(SEXPR_STR, tok->payload, 0));
    }
    if (t == TAG_CHAR) {
        advance(cur);
        return result_ok(sexpr_make(SEXPR_CHAR, tok->payload, 0));
    }
    if (t == TAG_LPAREN) {
        advance(cur);
        return list_result(toks, cur);
    }
    if (t == TAG_LBRACKET) {
        advance(cur);
        return bracket_list_result(toks, cur);
    }
    if (prefix_tag(t)) {
        int64_t name = prefix_symbol(t);
        ResultSexpr inner;
        advance(cur);
        inner = form_result(toks, cur);
        if (inner.tag == RESULT_OK) {
            return result_ok(prefix_form(name, inner.form));
        }
        return inner;
    }
    if (t == TAG_RPAREN) {
        return result_err(ERR_UNEXPECTED_RPAREN);
    }
    if (t == TAG_RBRACKET) {
        return result_err(ERR_UNEXPECTED_RBRACKET);
    }
    return result_err(ERR_UNEXPECTED_END);
}

/* list_result_with_close: the cursor is positioned just AFTER an opening '('.
 * Read forms until the matching ')' into a growable temporary builder;
 * completing the form copies that builder once into a contiguous child range in
 * source order. Nesting is handled for free: a head form that starts with '('
 * re-enters `form_result` -> `list_result`, completes its own child range, and
 * then becomes one value in this builder. */
static ResultSexpr list_result_with_close(const Token *toks, int64_t *cur,
                                          int64_t close_tag,
                                          int64_t unterminated_message,
                                          SexprBuilder builder) {
    int64_t t = peek_tag(toks, cur);
    if (t == close_tag) {
        /* End of this list: consume the ')' and seal the dense child range. */
        advance(cur);
        return result_ok(sexpr_list_from_builder(builder));
    }
    if (t == TAG_END) {
        return result_err(unterminated_message);
    } else {
        /* A list element: read the next form (which advances the cursor past
         * it, however deeply nested), append it, and continue. */
        ResultSexpr head = form_result(toks, cur);
        if (head.tag == RESULT_OK) {
            return list_result_with_close(toks, cur, close_tag,
                                          unterminated_message,
                                          sexpr_builder_push(builder,
                                                             head.form));
        }
        return head;
    }
}

static ResultSexpr list_result(const Token *toks, int64_t *cur) {
    int64_t pool_mark = sexpr_node_pool_len();
    SexprBuilder builder = sexpr_builder_new();
    ResultSexpr result = list_result_with_close(
        toks, cur, TAG_RPAREN, ERR_UNTERMINATED_PAREN, builder);
    if (result.tag == RESULT_OK) {
        return result;
    }
    sexpr_builder_discard(builder);
    sexpr_node_pool_truncate(pool_mark);
    return result;
}

static ResultSexpr bracket_list_result(const Token *toks, int64_t *cur) {
    int64_t pool_mark = sexpr_node_pool_len();
    SexprBuilder builder = sexpr_builder_new();
    ResultSexpr result = list_result_with_close(
        toks, cur, TAG_RBRACKET, ERR_UNTERMINATED_BRACKET, builder);
    if (result.tag == RESULT_OK) {
        return result;
    }
    sexpr_builder_discard(builder);
    sexpr_node_pool_truncate(pool_mark);
    return result;
}

/* `read.result`: reset the pool, then read one top-level form. */
static ResultSexpr rs_result(void) {
    sexpr_node_pool_reset();
    return form_result(rs_toks, rs_cur);
}

/* `read`: the panicking wrapper the loader's non-diagnostic path uses. */
static Sexpr rs_read(void) {
    ResultSexpr result = rs_result();
    if (result.tag != RESULT_OK) {
        fputs("reader: malformed corpus\n", stderr);
        abort();
    }
    return result.form;
}

/* ------------------------------------------------------------------------ */
/* The consumer: the recursive `sexpr-view` walk a parser performs.          */
/* ------------------------------------------------------------------------ */

static uint64_t sexpr_walk(Sexpr s, int64_t depth, uint64_t hash) {
    SexprView view;
    rs_walk_nodes += 1;
    if (depth > rs_walk_depth) {
        rs_walk_depth = depth;
    }
    view = sexpr_view(s);
    switch (view.tag) {
    case VIEW_INT:
        return rs_mix(hash, view.head.a);
    case VIEW_SYM:
        return rs_mix(hash, view.head.a);
    case VIEW_NIL:
        return rs_mix(hash, depth);
    case VIEW_CONS:
        return sexpr_walk(view.tail, depth,
                          sexpr_walk(view.head, depth + 1, hash));
    case VIEW_STR:
        return rs_mix(hash, view.head.a);
    case VIEW_CHAR:
        return rs_mix(hash, view.head.a);
    default:
        return rs_mix(hash, view.head.a);
    }
}

/* ------------------------------------------------------------------------ */
/* Driver.                                                                   */
/* ------------------------------------------------------------------------ */

/* One file: the loader's top-level loop. Read forms until the file's `End`
 * token, resetting the pool before each one, and walk every form. */
static uint64_t rs_file(int64_t start, uint64_t hash) {
    uint64_t acc = hash;
    rs_cur[0] = start;
    while (peek_tag(rs_toks, rs_cur) != TAG_END) {
        Sexpr form = rs_read();
        rs_forms += 1;
        rs_nodes += sexpr_node_pool_len();
        acc = sexpr_walk(form, 0, acc);
    }
    return acc;
}

static int64_t rs_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    char *text = rs_read_file(path, &length);
    int64_t capacity = length / 2 + 8;
    int64_t *tokens = rs_alloc_i64(capacity);
    int64_t *file_start;
    int64_t scanned;
    int64_t ntokens;
    int64_t nfiles;
    int64_t round = 0;
    int64_t start = 0;
    int64_t i;
    int64_t files;
    uint64_t acc = RS_HASH_BASIS;

    scanned = rs_scan_ints(text, length, tokens);
    acc = rs_mix(acc, scanned);
    ntokens = tokens[0];
    nfiles = tokens[1];
    file_start = rs_alloc_i64(nfiles + 1);
    rs_toks = (Token *)calloc((size_t)ntokens + 1, sizeof(Token));
    if (!rs_toks) {
        abort();
    }
    file_start[0] = 0;
    files = 1;
    for (i = 0; i < ntokens; i += 1) {
        int64_t tag = tokens[2 + i * 2];
        rs_toks[i].tag = tag;
        rs_toks[i].payload = tokens[3 + i * 2];
        if (tag == TAG_END && files < nfiles) {
            file_start[files] = i + 1;
            files += 1;
        }
    }

    while (round < rounds) {
        int64_t step = 0;
        acc = rs_mix(acc, round);
        rs_forms = 0;
        rs_nodes = 0;
        rs_walk_nodes = 0;
        rs_walk_depth = 0;
        while (step < nfiles) {
            int64_t index = start + step;
            if (index >= nfiles) {
                index -= nfiles;
            }
            acc = rs_file(file_start[index], acc);
            step += 1;
        }
        if (rs_forms != EXPECT_FORMS || rs_nodes != EXPECT_NODES) {
            fputs("read_sexpr: self-check failed\n", stderr);
            abort();
        }
        acc = rs_mix(acc, rs_forms);
        acc = rs_mix(acc, rs_nodes);
        acc = rs_mix(acc, rs_walk_nodes);
        acc = rs_mix(acc, rs_walk_depth);
        start += 1;
        if (start >= nfiles) {
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
    printf("%lld\n", (long long)rs_bench(path, rounds));
    return 0;
}
