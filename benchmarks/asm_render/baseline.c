/* benchmarks/asm_render/baseline.c - clang C baseline for asm_render.
 *
 * Equivalent to benchmarks/asm_render/bench.tl: the TypeLisp backend's own
 * assembly text emission, run over the real token stream of a slice of the
 * assembly the stage0 compiler emitted for src/compiler_load.tl (see README.md
 * for the corpus).
 *
 * Mirrored functions:
 *   src/compiler_backend.tl
 *     compiler-backend-asm-buf-with-capacity / -grow! / -reserve! / -finish
 *     compiler-backend-asm-copy-part!   -- the inline word-then-tail part copy
 *     compiler-backend-asm-append / -append2 / -append4 / -append5
 *     compiler-backend-reg-part / -reg-part-by-size
 *     compiler-backend-address-add-byte-offset
 *     compiler-backend-frame-offset-render / -stack-memory-operand
 *     compiler-backend-append-located-instr  (body chunk -> module TextBuf)
 *   stdlib/str_cat_runtime.tl  str-cat's expansions: concat3/4/5 for two to
 *     five parts, str-cat-pack-new + str-cat-concat-packed for six or more
 *   stdlib/string.tl  concat3/4/5, concat-all, int->string and its digit-count
 *     ladder and negative-digit writer (ported byte for byte, no snprintf)
 *   stdlib/text_buf.tl  append / render and the chunk store growth policy
 *
 * Both sides allocate one String per operand helper result and one per built
 * line, out of a bump arena that is reset (not freed) once per round, which is
 * how the backend's operand storage arena behaves.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the FNV-1a checksum here is formed in
 * uint64_t so the C side wraps identically. The printed decimal is the checksum
 * reinterpreted as a signed 64-bit integer, matching TypeLisp's print of an
 * i64.
 */
/* MSVC-clang deprecates fopen; the CI gate treats any stderr as failure. */
#define _CRT_SECURE_NO_WARNINGS
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define ASM_HASH_BASIS 1469598103934665603ULL
#define ASM_HASH_PRIME 1099511628211ULL

/* compiler-backend-asm-bytes-per-instr. */
#define ASM_BYTES_PER_LINE 64

/* stdlib/text_buf.tl: the chunk store's first capacity and its small-chunk
 * render limit. */
#define TEXT_BUF_STORE_CAPACITY 32
#define TEXT_BUF_SMALL_CHUNK_LIMIT 16

typedef struct {
    const unsigned char *data;
    int64_t len;
} asm_string;

/* --------------------------------------------------------------------------
 * Round arena: the active arena every operand String, line String, body buffer
 * and rendered text is allocated in. Reset, not freed, once per round.
 * -------------------------------------------------------------------------- */

static unsigned char *asm_arena_base;
static int64_t asm_arena_cap;
static int64_t asm_arena_used;

static unsigned char *asm_arena_alloc(int64_t bytes) {
    int64_t offset = asm_arena_used;
    int64_t padded = (bytes + 7) & ~(int64_t)7;
    if (padded < 0 || offset + padded > asm_arena_cap) {
        abort();
    }
    asm_arena_used = offset + padded;
    return asm_arena_base + offset;
}

static void asm_arena_reset(void) { asm_arena_used = 0; }

/* --------------------------------------------------------------------------
 * stdlib/string.tl byte copies and concatenation.
 * -------------------------------------------------------------------------- */

/* str-copy-owned-bytes-into / str-copy-borrowed-bytes-into: whole words first,
 * then the tail bytes. */
static void asm_copy_bytes_into(const unsigned char *src, unsigned char *dst,
                                int64_t start, int64_t n) {
    int64_t words = n / 8;
    int64_t w = 0;
    int64_t b = words * 8;
    while (w < words) {
        uint64_t value;
        memcpy(&value, src + w * 8, sizeof(value));
        memcpy(dst + start + w * 8, &value, sizeof(value));
        w += 1;
    }
    while (b < n) {
        dst[start + b] = src[b];
        b += 1;
    }
}

static asm_string asm_string_make(const unsigned char *data, int64_t len) {
    asm_string out;
    out.data = data;
    out.len = len;
    return out;
}

static asm_string asm_string_empty(void) {
    return asm_string_make((const unsigned char *)"", 0);
}

static asm_string asm_concat3(asm_string a, asm_string b, asm_string c) {
    int64_t total = a.len + (b.len + c.len);
    unsigned char *dst;
    if (total == 0) {
        return asm_string_empty();
    }
    dst = asm_arena_alloc(total);
    asm_copy_bytes_into(a.data, dst, 0, a.len);
    asm_copy_bytes_into(b.data, dst, a.len, b.len);
    asm_copy_bytes_into(c.data, dst, a.len + b.len, c.len);
    return asm_string_make(dst, total);
}

static asm_string asm_concat5(asm_string a, asm_string b, asm_string c,
                              asm_string d, asm_string e) {
    int64_t total = a.len + (b.len + (c.len + (d.len + e.len)));
    unsigned char *dst;
    if (total == 0) {
        return asm_string_empty();
    }
    dst = asm_arena_alloc(total);
    asm_copy_bytes_into(a.data, dst, 0, a.len);
    asm_copy_bytes_into(b.data, dst, a.len, b.len);
    asm_copy_bytes_into(c.data, dst, a.len + b.len, c.len);
    asm_copy_bytes_into(d.data, dst, a.len + (b.len + c.len), d.len);
    asm_copy_bytes_into(e.data, dst, a.len + (b.len + (c.len + d.len)), e.len);
    return asm_string_make(dst, total);
}

/* concat-all over the parts array str-cat-pack-new allocated. */
static asm_string asm_concat_all(const asm_string *parts, int64_t count) {
    int64_t index = 0;
    int64_t total = 0;
    int64_t offset = 0;
    unsigned char *dst;
    while (index < count) {
        total += parts[index].len;
        index += 1;
    }
    dst = asm_arena_alloc(total);
    index = 0;
    while (index < count) {
        asm_copy_bytes_into(parts[index].data, dst, offset, parts[index].len);
        offset += parts[index].len;
        index += 1;
    }
    return asm_string_make(dst, total);
}

/* str-cat with six or more operands: one zeroed parts array, then concat-all. */
static asm_string asm_str_cat_packed(const asm_string *parts, int64_t count) {
    asm_string *pack = (asm_string *)asm_arena_alloc(
        count * (int64_t)sizeof(asm_string));
    int64_t index = 0;
    memset(pack, 0, (size_t)count * sizeof(asm_string));
    while (index < count) {
        pack[index] = parts[index];
        index += 1;
    }
    return asm_concat_all(pack, count);
}

/* int->string-negative-digit-count: a comparison ladder, not a division loop. */
static int64_t asm_negative_digit_count(int64_t value) {
    if (value > -10) return 1;
    if (value > -100) return 2;
    if (value > -1000) return 3;
    if (value > -10000) return 4;
    if (value > -100000) return 5;
    if (value > -1000000) return 6;
    if (value > -10000000) return 7;
    if (value > -100000000) return 8;
    if (value > -1000000000) return 9;
    if (value > -10000000000) return 10;
    if (value > -100000000000) return 11;
    if (value > -1000000000000) return 12;
    if (value > -10000000000000) return 13;
    if (value > -100000000000000) return 14;
    if (value > -1000000000000000) return 15;
    if (value > -10000000000000000) return 16;
    if (value > -100000000000000000) return 17;
    if (value > -1000000000000000000) return 18;
    return 19;
}

static void asm_write_negative_digits(unsigned char *dst, int64_t base,
                                      int64_t value, int64_t digits) {
    int64_t cursor = value;
    int64_t index = digits - 1;
    while (index >= 0) {
        int64_t next = cursor / 10;
        int64_t digit = next * 10 - cursor;
        dst[base + index] = (unsigned char)(48 + digit);
        cursor = next;
        index -= 1;
    }
}

static asm_string asm_int_to_string(int64_t value) {
    int negative = value < 0;
    int64_t magnitude = negative ? value : -value;
    int64_t digits = asm_negative_digit_count(magnitude);
    int64_t len = negative ? digits + 1 : digits;
    unsigned char *buf = asm_arena_alloc(len);
    if (negative) {
        buf[0] = 45;
    }
    asm_write_negative_digits(buf, negative ? 1 : 0, magnitude, digits);
    return asm_string_make(buf, len);
}

/* --------------------------------------------------------------------------
 * CompilerBackendAsmBuf.
 * -------------------------------------------------------------------------- */

typedef struct {
    unsigned char *data;
    int64_t cap;
    int64_t len;
} asm_buf;

static asm_buf asm_buf_with_capacity(int64_t capacity) {
    asm_buf out;
    int64_t cap = capacity < 16 ? 16 : capacity;
    out.data = asm_arena_alloc(cap);
    out.cap = cap;
    out.len = 0;
    return out;
}

static void asm_buf_grow(asm_buf *buf, int64_t needed) {
    int64_t doubled = buf->cap * 2;
    int64_t capacity = doubled < needed ? needed : doubled;
    unsigned char *bigger = asm_arena_alloc(capacity);
    asm_copy_bytes_into(buf->data, bigger, 0, buf->len);
    buf->data = bigger;
    buf->cap = capacity;
}

static void asm_buf_reserve(asm_buf *buf, int64_t total) {
    if (total > buf->cap) {
        asm_buf_grow(buf, total);
    }
}

/* compiler-backend-asm-copy-part!: one move loop, no call frames. */
static void asm_copy_part(unsigned char *dst, int64_t off, asm_string src,
                          int64_t n) {
    int64_t words = n / 8;
    int64_t w = 0;
    int64_t b = words * 8;
    while (w < words) {
        uint64_t value;
        memcpy(&value, src.data + w * 8, sizeof(value));
        memcpy(dst + off + w * 8, &value, sizeof(value));
        w += 1;
    }
    while (b < n) {
        dst[off + b] = src.data[b];
        b += 1;
    }
}

static void asm_append(asm_buf *buf, asm_string part) {
    int64_t n = part.len;
    int64_t off;
    if (n == 0) {
        return;
    }
    off = buf->len;
    asm_buf_reserve(buf, off + n);
    asm_copy_part(buf->data, off, part, n);
    buf->len = off + n;
}

static void asm_append2(asm_buf *buf, asm_string a, asm_string b) {
    int64_t total = a.len + b.len;
    int64_t off = buf->len;
    unsigned char *dst;
    asm_buf_reserve(buf, off + total);
    dst = buf->data;
    asm_copy_part(dst, off, a, a.len);
    asm_copy_part(dst, off + a.len, b, b.len);
    buf->len = off + total;
}

static void asm_append4(asm_buf *buf, asm_string a, asm_string b, asm_string c,
                        asm_string d) {
    int64_t total = a.len + (b.len + (c.len + d.len));
    int64_t off = buf->len;
    unsigned char *dst;
    int64_t ob, oc, od;
    asm_buf_reserve(buf, off + total);
    dst = buf->data;
    ob = off + a.len;
    oc = ob + b.len;
    od = oc + c.len;
    asm_copy_part(dst, off, a, a.len);
    asm_copy_part(dst, ob, b, b.len);
    asm_copy_part(dst, oc, c, c.len);
    asm_copy_part(dst, od, d, d.len);
    buf->len = off + total;
}

static void asm_append5(asm_buf *buf, asm_string a, asm_string b, asm_string c,
                        asm_string d, asm_string e) {
    int64_t total = a.len + (b.len + (c.len + (d.len + e.len)));
    int64_t off = buf->len;
    unsigned char *dst;
    int64_t ob, oc, od, oe;
    asm_buf_reserve(buf, off + total);
    dst = buf->data;
    ob = off + a.len;
    oc = ob + b.len;
    od = oc + c.len;
    oe = od + d.len;
    asm_copy_part(dst, off, a, a.len);
    asm_copy_part(dst, ob, b, b.len);
    asm_copy_part(dst, oc, c, c.len);
    asm_copy_part(dst, od, d, d.len);
    asm_copy_part(dst, oe, e, e.len);
    buf->len = off + total;
}

static asm_string asm_buf_finish(const asm_buf *buf) {
    if (buf->len == 0) {
        return asm_string_empty();
    }
    return asm_string_make(buf->data, buf->len);
}

/* --------------------------------------------------------------------------
 * stdlib/text_buf.tl: the module-level chunk list.
 * -------------------------------------------------------------------------- */

typedef struct {
    int kind; /* 0 nil, 1 inline, 2 dense */
    asm_string inline_chunk;
    asm_string *slots;
    int64_t cap;
    int64_t count;
    int64_t len;
} asm_text_buf;

static void asm_text_buf_empty(asm_text_buf *buf) {
    buf->kind = 0;
    buf->inline_chunk = asm_string_empty();
    buf->slots = 0;
    buf->cap = 0;
    buf->count = 0;
    buf->len = 0;
}

static asm_string *asm_text_buf_store_new(void) {
    int64_t bytes = TEXT_BUF_STORE_CAPACITY * (int64_t)sizeof(asm_string);
    asm_string *slots = (asm_string *)asm_arena_alloc(bytes);
    memset(slots, 0, (size_t)bytes);
    return slots;
}

/* text-buf-owned-store-commit!: in place while the store has room, otherwise
 * text-buf-store-copy-and-commit's doubling with a prefix copy. */
static void asm_text_buf_commit(asm_text_buf *buf, asm_string entry) {
    if (buf->count < buf->cap) {
        buf->slots[buf->count] = entry;
        buf->count += 1;
        return;
    }
    {
        int64_t doubled = buf->cap < 1 ? 1 : buf->cap * 2;
        int64_t capacity = doubled < buf->count + 1 ? buf->count + 1 : doubled;
        int64_t bytes = capacity * (int64_t)sizeof(asm_string);
        asm_string *slots = (asm_string *)asm_arena_alloc(bytes);
        memset(slots, 0, (size_t)bytes);
        asm_copy_bytes_into((const unsigned char *)buf->slots,
                            (unsigned char *)slots, 0,
                            buf->count * (int64_t)sizeof(asm_string));
        buf->slots = slots;
        buf->cap = capacity;
        buf->slots[buf->count] = entry;
        buf->count += 1;
    }
}

static void asm_text_buf_append(asm_text_buf *buf, asm_string chunk) {
    if (chunk.len == 0) {
        return;
    }
    if (buf->kind == 0) {
        buf->inline_chunk = chunk;
        buf->kind = 1;
    } else if (buf->kind == 1) {
        buf->slots = asm_text_buf_store_new();
        buf->cap = TEXT_BUF_STORE_CAPACITY;
        buf->count = 0;
        asm_text_buf_commit(buf, buf->inline_chunk);
        asm_text_buf_commit(buf, chunk);
        buf->kind = 2;
    } else {
        asm_text_buf_commit(buf, chunk);
    }
    buf->len += chunk.len;
}

/* copy-chunk-into: the same word-then-tail copy. */
static void asm_copy_chunk_into(asm_string chunk, unsigned char *dst,
                                int64_t start) {
    asm_copy_bytes_into(chunk.data, dst, start, chunk.len);
}

/* fill-rev-into: chunks walked last to first, small chunks copied byte-wise. */
static void asm_fill_rev_into(const asm_text_buf *buf, unsigned char *dst,
                              int64_t pos) {
    if (buf->kind == 0) {
        return;
    }
    if (buf->kind == 1) {
        asm_string chunk = buf->inline_chunk;
        int64_t start = pos - chunk.len;
        if (chunk.len <= TEXT_BUF_SMALL_CHUNK_LIMIT) {
            int64_t index = 0;
            while (index < chunk.len) {
                dst[start + index] = chunk.data[index];
                index += 1;
            }
        } else {
            asm_copy_chunk_into(chunk, dst, start);
        }
        return;
    }
    {
        int64_t cursor = buf->count - 1;
        int64_t out_pos = pos;
        while (cursor >= 0) {
            asm_string chunk = buf->slots[cursor];
            int64_t start = out_pos - chunk.len;
            if (chunk.len <= TEXT_BUF_SMALL_CHUNK_LIMIT) {
                int64_t index = 0;
                while (index < chunk.len) {
                    dst[start + index] = chunk.data[index];
                    index += 1;
                }
            } else {
                asm_copy_chunk_into(chunk, dst, start);
            }
            out_pos = start;
            cursor -= 1;
        }
    }
}

/* render-chunks: `__tl_make-array u8 total` hands out zeroed storage, so the
 * mirror zeroes it too before filling. */
static asm_string asm_text_buf_render(const asm_text_buf *buf) {
    unsigned char *dst;
    if (buf->len == 0) {
        return asm_string_empty();
    }
    dst = asm_arena_alloc(buf->len);
    memset(dst, 0, (size_t)buf->len);
    asm_fill_rev_into(buf, dst, buf->len);
    return asm_string_make(dst, buf->len);
}

/* --------------------------------------------------------------------------
 * Corpus state.
 * -------------------------------------------------------------------------- */

static int64_t *asm_tokens;
static int64_t *asm_chunk_off;
static int64_t *asm_chunk_lines;
static int64_t asm_kind_counts[8];
static asm_string *asm_names;

static int64_t asm_names_count;
static int64_t asm_chunks;
static int64_t asm_lines;
static int64_t asm_slice_bytes;
static int64_t asm_slice_fnv;
static int64_t asm_cursor;

static uint64_t asm_mix(uint64_t hash, uint64_t value) {
    return (hash ^ value) * ASM_HASH_PRIME;
}

static int64_t asm_tok_next(void) {
    int64_t value = asm_tokens[asm_cursor];
    asm_cursor += 1;
    return value;
}

static asm_string asm_name(int64_t id) { return asm_names[id]; }

/* --------------------------------------------------------------------------
 * Operand rendering.
 * -------------------------------------------------------------------------- */

/* A string literal, with its length known at compile time exactly as a
 * TypeLisp `String` literal carries its own length. */
#define ASM_LIT(text) \
    asm_string_make((const unsigned char *)(text), (int64_t)(sizeof(text) - 1))

/* The literal register parts compiler-backend-reg-part-by-size selects from. */
static const char *const ASM_REG_TABLE[15][4] = {
    {"%rax", "%eax", "%ax", "%al"},
    {"%rbx", "%ebx", "%bx", "%bl"},
    {"%rcx", "%ecx", "%cx", "%cl"},
    {"%rdx", "%edx", "%dx", "%dl"},
    {"%rdi", "%edi", "%di", "%dil"},
    {"%rsi", "%esi", "%si", "%sil"},
    {"%r12", "%r12d", "%r12w", "%r12b"},
    {"%r13", "%r13d", "%r13w", "%r13b"},
    {"%r14", "%r14d", "%r14w", "%r14b"},
    {"%r15", "%r15d", "%r15w", "%r15b"},
    {"%r8", "%r8d", "%r8w", "%r8b"},
    {"%r9", "%r9d", "%r9w", "%r9b"},
    {"%r10", "%r10d", "%r10w", "%r10b"},
    {"%r11", "%r11d", "%r11w", "%r11b"},
    {"%rbp", "%ebp", "%bp", "%bpl"},
};

static asm_string asm_reg_parts[15][4];

static void asm_init_register_parts(void) {
    int row = 0;
    while (row < 15) {
        int column = 0;
        while (column < 4) {
            asm_reg_parts[row][column] = asm_string_make(
                (const unsigned char *)ASM_REG_TABLE[row][column],
                (int64_t)strlen(ASM_REG_TABLE[row][column]));
            column += 1;
        }
        row += 1;
    }
}

/* string.eq: length, then pointer identity, then whole words and the tail. */
static int asm_string_eq(asm_string left, asm_string right) {
    int64_t words;
    int64_t i = 0;
    int64_t b;
    if (left.len != right.len) {
        return 0;
    }
    if (left.data == right.data) {
        return 1;
    }
    words = left.len >> 3;
    while (i < words) {
        uint64_t lw;
        uint64_t rw;
        memcpy(&lw, left.data + i * 8, sizeof(lw));
        memcpy(&rw, right.data + i * 8, sizeof(rw));
        if (lw != rw) {
            return 0;
        }
        i += 1;
    }
    b = words * 8;
    while (b < left.len) {
        if (left.data[b] != right.data[b]) {
            return 0;
        }
        b += 1;
    }
    return 1;
}

static asm_string asm_reg_part_by_size(asm_string reg64, asm_string reg32,
                                       asm_string reg16, asm_string reg8,
                                       int64_t size) {
    if (size == 8) return reg64;
    if (size == 4) return reg32;
    if (size == 2) return reg16;
    if (size == 1) return reg8;
    fprintf(stderr, "asm_render: unsupported register part size");
    abort();
}

static asm_string asm_reg_part(asm_string reg, int64_t size) {
    int index = 0;
    while (index < 15) {
        if (asm_string_eq(reg, asm_reg_parts[index][0])) {
            return asm_reg_part_by_size(reg, asm_reg_parts[index][1],
                                        asm_reg_parts[index][2],
                                        asm_reg_parts[index][3], size);
        }
        index += 1;
    }
    fprintf(stderr, "asm_render: unsupported register part");
    abort();
}

static asm_string asm_address_add_byte_offset(asm_string addr, int64_t disp) {
    asm_string disp_text;
    if (disp == 0) {
        return addr;
    }
    disp_text = asm_int_to_string(disp);
    if (addr.len > 0 && addr.data[0] == '(') {
        return asm_concat3(disp_text, addr, asm_string_empty());
    }
    return asm_concat3(disp_text, ASM_LIT("+"), addr);
}

static asm_string asm_mem_operand(asm_string base, asm_string index,
                                  int has_index, int64_t scale, int64_t disp,
                                  int disp_present) {
    asm_string scale_text = has_index ? asm_int_to_string(scale)
                                      : asm_string_empty();
    asm_string addr;
    if (has_index) {
        /* str-cat of seven operands: one packed parts array, then concat-all. */
        asm_string parts[7];
        parts[0] = ASM_LIT("(");
        parts[1] = base;
        parts[2] = ASM_LIT(",");
        parts[3] = index;
        parts[4] = ASM_LIT(",");
        parts[5] = scale_text;
        parts[6] = ASM_LIT(")");
        addr = asm_str_cat_packed(parts, 7);
    } else {
        addr = asm_concat3(ASM_LIT("("), base, ASM_LIT(")"));
    }
    if (disp_present) {
        if (disp == 0) {
            return asm_concat3(asm_int_to_string(disp), addr,
                               asm_string_empty());
        }
        return asm_address_add_byte_offset(addr, disp);
    }
    return addr;
}

static asm_string asm_imm_operand(int64_t value) {
    asm_string text = asm_int_to_string(value);
    return asm_concat3(ASM_LIT("$"), text, asm_string_empty());
}

static asm_string asm_rip_operand(asm_string symbol) {
    return asm_concat3(symbol, ASM_LIT("(%rip)"), asm_string_empty());
}

static asm_string asm_next_operand(void) {
    int64_t kind = asm_tok_next();
    if (kind == 0) {
        asm_string reg = asm_name(asm_tok_next());
        int64_t size = asm_tok_next();
        return asm_reg_part(reg, size);
    }
    if (kind == 1) {
        return asm_imm_operand(asm_tok_next());
    }
    if (kind == 2) {
        return asm_int_to_string(asm_tok_next());
    }
    if (kind == 3) {
        int64_t base_id = asm_tok_next();
        int64_t index_id = asm_tok_next();
        int64_t scale = asm_tok_next();
        int64_t disp = asm_tok_next();
        int64_t present = asm_tok_next();
        asm_string base = asm_name(base_id);
        asm_string index = index_id >= 0 ? asm_name(index_id)
                                         : asm_string_empty();
        return asm_mem_operand(base, index, index_id >= 0, scale, disp,
                               present == 1);
    }
    if (kind == 4) {
        return asm_rip_operand(asm_name(asm_tok_next()));
    }
    return asm_name(asm_tok_next());
}

/* --------------------------------------------------------------------------
 * Line rendering.
 * -------------------------------------------------------------------------- */

/* Three-operand lines take the seven-part `str-cat`, which packs. */
static asm_string asm_three_operand_line(asm_string head) {
    asm_string parts[7];
    parts[0] = head;
    parts[1] = asm_next_operand();
    parts[2] = ASM_LIT(", ");
    parts[3] = asm_next_operand();
    parts[4] = ASM_LIT(", ");
    parts[5] = asm_next_operand();
    parts[6] = ASM_LIT("\n");
    return asm_str_cat_packed(parts, 7);
}

static int64_t asm_render_line(asm_buf *buf) {
    int64_t kind = asm_tok_next();
    asm_string head;
    int64_t nops;
    if (kind == 0) {
        asm_append(buf, ASM_LIT("\n"));
        return kind;
    }
    if (kind == 1) {
        asm_string text = asm_name(asm_tok_next());
        asm_append2(buf, text, ASM_LIT("\n"));
        return kind;
    }
    if (kind == 2) {
        asm_string label = asm_name(asm_tok_next());
        asm_append2(buf, label, ASM_LIT(":\n"));
        return kind;
    }
    head = asm_name(asm_tok_next());
    nops = asm_tok_next();
    if (kind == 3) {
        if (nops == 0) {
            asm_append(buf, asm_concat3(head, ASM_LIT("\n"),
                                        asm_string_empty()));
        } else if (nops == 1) {
            asm_string a = asm_next_operand();
            asm_append(buf, asm_concat3(head, a, ASM_LIT("\n")));
        } else if (nops == 2) {
            asm_string a = asm_next_operand();
            asm_string b = asm_next_operand();
            asm_append(buf, asm_concat5(head, a, ASM_LIT(", "), b,
                                        ASM_LIT("\n")));
        } else {
            asm_append(buf, asm_three_operand_line(head));
        }
        return kind;
    }
    if (nops == 0) {
        asm_append2(buf, head, ASM_LIT("\n"));
    } else if (nops == 1) {
        asm_string a = asm_next_operand();
        asm_append4(buf, head, a, ASM_LIT("\n"), asm_string_empty());
    } else if (nops == 2) {
        asm_string a = asm_next_operand();
        asm_string b = asm_next_operand();
        asm_append5(buf, head, a, ASM_LIT(", "), b, ASM_LIT("\n"));
    } else {
        asm_append(buf, asm_three_operand_line(head));
    }
    return kind;
}

static void asm_render_chunk(int64_t chunk, asm_text_buf *out) {
    int64_t lines = asm_chunk_lines[chunk];
    asm_buf buf = asm_buf_with_capacity(lines * ASM_BYTES_PER_LINE);
    int64_t i = 0;
    asm_cursor = asm_chunk_off[chunk];
    while (i < lines) {
        int64_t kind = asm_render_line(&buf);
        asm_kind_counts[kind] += 1;
        i += 1;
    }
    asm_text_buf_append(out, asm_buf_finish(&buf));
}

static uint64_t asm_fold_text(uint64_t hash, asm_string text) {
    int64_t i = 0;
    uint64_t h = hash;
    while (i < text.len) {
        h = asm_mix(h, (uint64_t)(int64_t)text.data[i]);
        i += 1;
    }
    return h;
}

static uint64_t asm_round(int64_t start) {
    asm_text_buf out;
    int64_t step = 0;
    int64_t kind = 0;
    uint64_t hash = ASM_HASH_BASIS;
    asm_string text;
    asm_text_buf_empty(&out);
    while (kind < 8) {
        asm_kind_counts[kind] = 0;
        kind += 1;
    }
    while (step < asm_chunks) {
        int64_t index = start + step;
        if (index >= asm_chunks) {
            index -= asm_chunks;
        }
        asm_render_chunk(index, &out);
        step += 1;
    }
    text = asm_text_buf_render(&out);
    hash = asm_fold_text(hash, text);
    if (start == 0 && (text.len != asm_slice_bytes ||
                       (int64_t)hash != asm_slice_fnv)) {
        fprintf(stderr,
                "asm_render: re-rendered text differs from the corpus slice");
        abort();
    }
    hash = asm_mix(hash, (uint64_t)text.len);
    kind = 0;
    while (kind < 8) {
        hash = asm_mix(hash, (uint64_t)asm_kind_counts[kind]);
        kind += 1;
    }
    return hash;
}

/* --------------------------------------------------------------------------
 * Corpus loading.
 * -------------------------------------------------------------------------- */

static char *asm_read_file(const char *path, int64_t *length) {
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

static int64_t asm_byte_at(const char *text, int64_t n, int64_t i) {
    if (i < n) {
        return (int64_t)(unsigned char)text[i];
    }
    return -1;
}

static int asm_is_digit(int64_t byte) { return byte >= 48 && byte <= 57; }

/* Whitespace-separated decimal integers, with `#` starting a comment that runs
 * to the end of its line. */
static int64_t asm_scan_ints(const char *text, int64_t n, int64_t *out) {
    int64_t i = 0;
    int64_t count = 0;
    while (i < n) {
        int64_t byte = asm_byte_at(text, n, i);
        if (byte == 35) {
            while (i < n && asm_byte_at(text, n, i) != 10) {
                i += 1;
            }
        } else if (asm_is_digit(byte) || byte == 45) {
            int negative = byte == 45;
            int64_t value = 0;
            if (negative) {
                i += 1;
            }
            while (asm_is_digit(asm_byte_at(text, n, i))) {
                value = value * 10 + (asm_byte_at(text, n, i) - 48);
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

static int64_t asm_operand_width(int64_t kind) {
    if (kind == 0) return 3;
    if (kind == 3) return 6;
    return 2;
}

static int64_t asm_row_width(int64_t at) {
    int64_t kind = asm_tokens[at];
    if (kind == 0) {
        return 1;
    }
    if (kind == 1 || kind == 2) {
        return 2;
    }
    {
        int64_t nops = asm_tokens[at + 2];
        int64_t width = 3;
        int64_t k = 0;
        while (k < nops) {
            width += asm_operand_width(asm_tokens[at + width]);
            k += 1;
        }
        return width;
    }
}

static void asm_index_chunks(void) {
    int64_t cursor = 5;
    int64_t chunk = 0;
    asm_chunk_off = (int64_t *)calloc((size_t)asm_chunks + 1,
                                      sizeof(int64_t));
    asm_chunk_lines = (int64_t *)calloc((size_t)asm_chunks + 1,
                                        sizeof(int64_t));
    if (!asm_chunk_off || !asm_chunk_lines) {
        abort();
    }
    while (chunk < asm_chunks) {
        int64_t lines = asm_tokens[cursor];
        int64_t i = 0;
        cursor += 1;
        asm_chunk_off[chunk] = cursor;
        asm_chunk_lines[chunk] = lines;
        while (i < lines) {
            cursor += asm_row_width(cursor);
            i += 1;
        }
        chunk += 1;
    }
}

/* The names live beside the tape: same directory, fixed file name. */
static char *asm_names_path(const char *path) {
    int64_t n = (int64_t)strlen(path);
    int64_t cut = 0;
    int64_t i = 0;
    char *out;
    const char *tail = "asm-names.txt";
    while (i < n) {
        if (path[i] == '/') {
            cut = i + 1;
        }
        i += 1;
    }
    out = (char *)malloc((size_t)cut + strlen(tail) + 1);
    if (!out) {
        abort();
    }
    memcpy(out, path, (size_t)cut);
    memcpy(out + cut, tail, strlen(tail) + 1);
    return out;
}

/* Two header lines, then one name per line in id order. Each name is copied,
 * the way `string.substring` copies into the active arena. */
static void asm_load_names(const char *text, int64_t n) {
    unsigned char *storage = (unsigned char *)malloc((size_t)n + 1);
    int64_t used = 0;
    int64_t i = 0;
    int64_t line = 0;
    int64_t start = 0;
    asm_names = (asm_string *)calloc((size_t)asm_names_count,
                                     sizeof(asm_string));
    if (!storage || !asm_names) {
        abort();
    }
    while (i < n) {
        if (text[i] == 10) {
            if (line >= 2 && line - 2 < asm_names_count) {
                int64_t len = i - start;
                memcpy(storage + used, text + start, (size_t)len);
                asm_names[line - 2] = asm_string_make(storage + used, len);
                used += len;
            }
            line += 1;
            start = i + 1;
        }
        i += 1;
    }
}

static uint64_t asm_bench(const char *path, int64_t rounds) {
    int64_t length = 0;
    int64_t names_length = 0;
    char *names_path = asm_names_path(path);
    char *text = asm_read_file(path, &length);
    char *names_text;
    int64_t capacity = length / 2 + 8;
    int64_t round = 0;
    int64_t start = 0;
    uint64_t acc = ASM_HASH_BASIS;
    int64_t arena_bytes;

    asm_init_register_parts();
    asm_tokens = (int64_t *)calloc((size_t)capacity, sizeof(int64_t));
    if (!asm_tokens) {
        abort();
    }
    acc = asm_mix(acc, (uint64_t)asm_scan_ints(text, length, asm_tokens));
    asm_names_count = asm_tokens[0];
    asm_chunks = asm_tokens[1];
    asm_lines = asm_tokens[2];
    asm_slice_bytes = asm_tokens[3];
    asm_slice_fnv = asm_tokens[4];

    names_text = asm_read_file(names_path, &names_length);
    asm_load_names(names_text, names_length);
    asm_index_chunks();
    acc = asm_mix(acc, (uint64_t)asm_lines);

    /* One round's peak: the per-function body buffers, the built strings, and
     * the rendered module text. */
    arena_bytes = asm_lines * ASM_BYTES_PER_LINE + asm_slice_bytes * 8 +
                  (1 << 20);
    asm_arena_base = (unsigned char *)malloc((size_t)arena_bytes);
    if (!asm_arena_base) {
        abort();
    }
    asm_arena_cap = arena_bytes;

    while (round < rounds) {
        acc = asm_mix(acc, (uint64_t)round);
        acc = asm_mix(acc, (uint64_t)start);
        asm_arena_reset();
        acc = asm_mix(acc, asm_round(start));
        start += 1;
        if (start >= asm_chunks) {
            start = 0;
        }
        round += 1;
    }
    return acc;
}

int main(int argc, char **argv) {
    const char *path = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)asm_bench(path, rounds));
    return 0;
}
