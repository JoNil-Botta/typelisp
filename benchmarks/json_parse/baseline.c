/* benchmarks/json_parse/baseline.c - clang C baseline for json_parse.
 *
 * Equivalent to benchmarks/json_parse/bench.tl: deterministically generates a
 * ~64 KB nested JSON corpus into a byte buffer, stamps the round counter into
 * the document header each round, parses the buffer via recursive descent into
 * a flat pre-allocated arena node pool (linked sibling chains), and recursively
 * walks the arena tree to fold a wrapping 64-bit FNV-1a checksum.
 */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define JP_HASH_BASIS 0xcbf29ce484222325ULL
#define JP_HASH_PRIME 1099511628211ULL

#define JP_KIND_NULL 0
#define JP_KIND_BOOL 1
#define JP_KIND_NUM 2
#define JP_KIND_STR 3
#define JP_KIND_ARR 4
#define JP_KIND_OBJ 5

typedef struct {
    int64_t pos;
    int64_t len;
    int64_t node_count;
    int64_t err;
} ParserState;

typedef struct {
    uint8_t *data;
    int64_t len;
    int64_t cap;
} ByteVec;

static uint64_t jp_mix(uint64_t h, uint64_t v) {
    return (h ^ v) * JP_HASH_PRIME;
}

static uint64_t jp_next_rng(uint64_t state) {
    return state * 6364136223846793005ULL + 1442695040888963407ULL;
}

static int64_t jp_rng_draw(uint64_t state) {
    return (int64_t)((state >> 33) & 2147483647ULL);
}

static void jp_buf_push_u8(ByteVec *buf, uint8_t b) {
    if (buf->len >= buf->cap) {
        int64_t new_cap = buf->cap > 0 ? buf->cap * 2 : 256;
        uint8_t *next = (uint8_t *)realloc(buf->data, (size_t)new_cap);
        if (!next) {
            abort();
        }
        buf->data = next;
        buf->cap = new_cap;
    }
    buf->data[buf->len++] = b;
}

static void jp_buf_push_str(ByteVec *buf, const char *s) {
    size_t n = strlen(s);
    for (size_t i = 0; i < n; i++) {
        jp_buf_push_u8(buf, (uint8_t)s[i]);
    }
}

static void jp_buf_push_i64(ByteVec *buf, int64_t val) {
    int64_t v = val;
    uint8_t digits[24];
    int64_t count = 0;
    if (v < 0) {
        jp_buf_push_u8(buf, 45);
        v = -v;
    }
    if (v == 0) {
        jp_buf_push_u8(buf, 48);
        return;
    }
    while (v > 0) {
        digits[count++] = (uint8_t)(48 + (v % 10));
        v /= 10;
    }
    while (count > 0) {
        jp_buf_push_u8(buf, digits[--count]);
    }
}

static int64_t jp_build_corpus(ByteVec *buf, int64_t records) {
    static const char *words[8] = {
        "alpha",
        "beta\\nline",
        "gamma\\\"q\\\"",
        "delta\\t1",
        "eps\\u0041z",
        "zeta\\/path",
        "eta\\\\slash",
        "theta\\r0",
    };
    uint64_t state = 20261127ULL;
    jp_buf_push_str(buf, "{\"meta\":{\"ver\":");
    int64_t ver_pos = buf->len;
    jp_buf_push_str(
        buf,
        "0000,\"ok\":true,\"empty\":null,\"label\":\"batch-\\\"alpha\\\"\\\\0\\n\\t\"},\n\"items\":[");
    for (int64_t i = 0; i < records; i++) {
        if (i > 0) {
            jp_buf_push_str(buf, ",\n");
        }
        state = jp_next_rng(state);
        int64_t d0 = jp_rng_draw(state);
        int64_t id = i * 17 + (d0 % 13);
        int sign_neg = (d0 & 1) == 1;
        int64_t w0 = d0 % 8;

        state = jp_next_rng(state);
        int64_t d1 = jp_rng_draw(state);
        int64_t w1 = d1 % 8;
        int64_t score = d1 % 9973;

        state = jp_next_rng(state);
        int64_t d2 = jp_rng_draw(state);
        int64_t frac = d2 % 1000;
        int64_t exp_val = (d2 % 7) - 3;
        int active = (d2 & 3) == 0;

        jp_buf_push_str(buf, "  {\"id\":");
        jp_buf_push_i64(buf, id);
        jp_buf_push_str(buf, ",\"name\":\"");
        jp_buf_push_str(buf, words[w0]);
        jp_buf_push_str(buf, "\",\"score\":");
        if (sign_neg) {
            jp_buf_push_u8(buf, 45);
        }
        jp_buf_push_i64(buf, score);
        jp_buf_push_u8(buf, 46);
        jp_buf_push_i64(buf, frac);
        if (exp_val != 0) {
            jp_buf_push_u8(buf, 101);
            jp_buf_push_i64(buf, exp_val);
        }
        jp_buf_push_str(buf, ",\"active\":");
        jp_buf_push_str(buf, active ? "true" : "false");
        jp_buf_push_str(buf, ",\"opt\":");
        if ((i % 3) == 0) {
            jp_buf_push_str(buf, "null");
        } else {
            jp_buf_push_u8(buf, 34);
            jp_buf_push_str(buf, words[w1]);
            jp_buf_push_u8(buf, 34);
        }
        jp_buf_push_str(buf, ",\"nums\":[");
        jp_buf_push_i64(buf, id - 50);
        jp_buf_push_u8(buf, 44);
        jp_buf_push_i64(buf, score + 1);
        jp_buf_push_u8(buf, 44);
        jp_buf_push_i64(buf, -frac);
        jp_buf_push_str(buf, "],\"meta\":{\"a\":");
        jp_buf_push_str(buf, ((i % 2) == 0) ? "true" : "false");
        jp_buf_push_str(buf, ",\"tags\":[\"");
        jp_buf_push_str(buf, words[(w0 + 1) % 8]);
        jp_buf_push_str(buf, "\",\"");
        jp_buf_push_str(buf, words[(w1 + 3) % 8]);
        jp_buf_push_str(buf, "\"]}}");
    }
    jp_buf_push_str(buf, "]}\n");
    return ver_pos;
}

static int64_t jp_alloc_node(ParserState *st, int64_t max_nodes,
                             int64_t *kinds, int64_t *vals, int64_t *keys,
                             int64_t *firsts, int64_t *nexts,
                             int64_t kind, int64_t val) {
    int64_t idx = st->node_count;
    if (idx >= max_nodes) {
        st->err = 1;
        return -1;
    }
    st->node_count = idx + 1;
    kinds[idx] = kind;
    vals[idx] = val;
    keys[idx] = 0;
    firsts[idx] = -1;
    nexts[idx] = -1;
    return idx;
}

static void jp_skip_ws(const uint8_t *src, ParserState *st) {
    int64_t p = st->pos;
    int64_t n = st->len;
    while (p < n) {
        int64_t c = (int64_t)src[p];
        if (c == 32 || c == 10 || c == 13 || c == 9) {
            p += 1;
        } else {
            break;
        }
    }
    st->pos = p;
}

static int64_t jp_hex_digit(int64_t c) {
    if (c >= 48 && c <= 57) return c - 48;
    if (c >= 65 && c <= 70) return (c - 65) + 10;
    if (c >= 97 && c <= 102) return (c - 97) + 10;
    return -1;
}

static int64_t jp_parse_string_hash(const uint8_t *src, ParserState *st) {
    int64_t p = st->pos;
    int64_t n = st->len;
    uint64_t h = JP_HASH_BASIS;
    int64_t count = 0;
    int done = 0;
    if (p >= n || src[p] != 34) {
        st->err = 2;
        return 0;
    }
    p += 1;
    while (p < n && !done) {
        int64_t c = (int64_t)src[p];
        if (c == 34) {
            p += 1;
            done = 1;
        } else if (c == 92) {
            p += 1;
            if (p >= n) {
                st->err = 3;
                done = 1;
            } else {
                int64_t esc = (int64_t)src[p++];
                if (esc == 34) { h = jp_mix(h, 34); count += 1; }
                else if (esc == 92) { h = jp_mix(h, 92); count += 1; }
                else if (esc == 47) { h = jp_mix(h, 47); count += 1; }
                else if (esc == 98) { h = jp_mix(h, 8); count += 1; }
                else if (esc == 102) { h = jp_mix(h, 12); count += 1; }
                else if (esc == 110) { h = jp_mix(h, 10); count += 1; }
                else if (esc == 114) { h = jp_mix(h, 13); count += 1; }
                else if (esc == 116) { h = jp_mix(h, 9); count += 1; }
                else if (esc == 117) {
                    if (p + 4 > n) {
                        st->err = 4;
                        done = 1;
                    } else {
                        int64_t d0 = jp_hex_digit((int64_t)src[p]);
                        int64_t d1 = jp_hex_digit((int64_t)src[p + 1]);
                        int64_t d2 = jp_hex_digit((int64_t)src[p + 2]);
                        int64_t d3 = jp_hex_digit((int64_t)src[p + 3]);
                        if (d0 < 0 || d1 < 0 || d2 < 0 || d3 < 0) {
                            st->err = 5;
                            done = 1;
                        } else {
                            int64_t cp = (d0 << 12) | (d1 << 8) | (d2 << 4) | d3;
                            p += 4;
                            h = jp_mix(h, (uint64_t)cp);
                            count += 1;
                        }
                    }
                } else {
                    st->err = 6;
                    done = 1;
                }
            }
        } else {
            p += 1;
            h = jp_mix(h, (uint64_t)c);
            count += 1;
        }
    }
    if (!done) {
        st->err = 7;
    }
    st->pos = p;
    return (int64_t)jp_mix(h, (uint64_t)count);
}

static int64_t jp_parse_number(const uint8_t *src, ParserState *st) {
    int64_t p = st->pos;
    int64_t n = st->len;
    int neg_sign = 0;
    int64_t int_part = 0;
    int64_t frac_part = 0;
    int64_t frac_digits = 0;
    int exp_neg = 0;
    int64_t exp_part = 0;
    int64_t digits = 0;
    if (p < n && src[p] == 45) {
        neg_sign = 1;
        p += 1;
    }
    while (p < n) {
        int64_t c = (int64_t)src[p];
        if (c >= 48 && c <= 57) {
            int_part = (int64_t)((uint64_t)int_part * 10ULL + (uint64_t)(c - 48));
            digits += 1;
            p += 1;
        } else {
            break;
        }
    }
    if (digits == 0) {
        st->err = 8;
    }
    if (p < n && src[p] == 46) {
        p += 1;
        while (p < n) {
            int64_t c = (int64_t)src[p];
            if (c >= 48 && c <= 57) {
                frac_part = (int64_t)((uint64_t)frac_part * 10ULL + (uint64_t)(c - 48));
                frac_digits += 1;
                p += 1;
            } else {
                break;
            }
        }
    }
    if (p < n && (src[p] == 101 || src[p] == 69)) {
        p += 1;
        if (p < n) {
            if (src[p] == 45) {
                exp_neg = 1;
                p += 1;
            } else if (src[p] == 43) {
                p += 1;
            }
        }
        while (p < n) {
            int64_t c = (int64_t)src[p];
            if (c >= 48 && c <= 57) {
                exp_part = (int64_t)((uint64_t)exp_part * 10ULL + (uint64_t)(c - 48));
                p += 1;
            } else {
                break;
            }
        }
    }
    st->pos = p;
    int64_t signed_int = neg_sign ? -int_part : int_part;
    int64_t signed_exp = exp_neg ? -exp_part : exp_part;
    return (int64_t)((uint64_t)signed_int * 1000003ULL +
                     (uint64_t)frac_part * 1009ULL +
                     (uint64_t)frac_digits * 37ULL +
                     (uint64_t)signed_exp);
}

static int64_t jp_parse_value(const uint8_t *src, ParserState *st,
                              int64_t max_nodes, int64_t *kinds, int64_t *vals,
                              int64_t *keys, int64_t *firsts, int64_t *nexts);

static int64_t jp_parse_array(const uint8_t *src, ParserState *st,
                              int64_t max_nodes, int64_t *kinds, int64_t *vals,
                              int64_t *keys, int64_t *firsts, int64_t *nexts) {
    st->pos += 1;
    int64_t node = jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts,
                                 nexts, JP_KIND_ARR, 0);
    if (node < 0) return -1;
    int64_t head = -1;
    int64_t tail = -1;
    int64_t count = 0;
    jp_skip_ws(src, st);
    if (st->pos < st->len && src[st->pos] == 93) {
        st->pos += 1;
        return node;
    }
    int cont = 1;
    while (cont && st->err == 0) {
        int64_t child = jp_parse_value(src, st, max_nodes, kinds, vals, keys,
                                       firsts, nexts);
        if (child < 0) {
            cont = 0;
            continue;
        }
        if (head < 0) head = child;
        else nexts[tail] = child;
        tail = child;
        count += 1;
        jp_skip_ws(src, st);
        if (st->pos >= st->len) {
            st->err = 9;
            cont = 0;
        } else {
            uint8_t sep = src[st->pos];
            if (sep == 44) {
                st->pos += 1;
            } else if (sep == 93) {
                st->pos += 1;
                cont = 0;
            } else {
                st->err = 10;
                cont = 0;
            }
        }
    }
    firsts[node] = head;
    vals[node] = count;
    return node;
}

static int64_t jp_parse_object(const uint8_t *src, ParserState *st,
                               int64_t max_nodes, int64_t *kinds, int64_t *vals,
                               int64_t *keys, int64_t *firsts, int64_t *nexts) {
    st->pos += 1;
    int64_t node = jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts,
                                 nexts, JP_KIND_OBJ, 0);
    if (node < 0) return -1;
    int64_t head = -1;
    int64_t tail = -1;
    int64_t count = 0;
    jp_skip_ws(src, st);
    if (st->pos < st->len && src[st->pos] == 125) {
        st->pos += 1;
        return node;
    }
    int cont = 1;
    while (cont && st->err == 0) {
        jp_skip_ws(src, st);
        int64_t key_hash = jp_parse_string_hash(src, st);
        if (st->err != 0) {
            cont = 0;
            continue;
        }
        jp_skip_ws(src, st);
        if (st->pos >= st->len || src[st->pos] != 58) {
            st->err = 11;
            cont = 0;
            continue;
        }
        st->pos += 1;
        int64_t child = jp_parse_value(src, st, max_nodes, kinds, vals, keys,
                                       firsts, nexts);
        if (child < 0) {
            cont = 0;
            continue;
        }
        keys[child] = key_hash;
        if (head < 0) head = child;
        else nexts[tail] = child;
        tail = child;
        count += 1;
        jp_skip_ws(src, st);
        if (st->pos >= st->len) {
            st->err = 12;
            cont = 0;
        } else {
            uint8_t sep = src[st->pos];
            if (sep == 44) {
                st->pos += 1;
            } else if (sep == 125) {
                st->pos += 1;
                cont = 0;
            } else {
                st->err = 13;
                cont = 0;
            }
        }
    }
    firsts[node] = head;
    vals[node] = count;
    return node;
}

static int64_t jp_parse_value(const uint8_t *src, ParserState *st,
                              int64_t max_nodes, int64_t *kinds, int64_t *vals,
                              int64_t *keys, int64_t *firsts, int64_t *nexts) {
    jp_skip_ws(src, st);
    if (st->pos >= st->len) {
        st->err = 14;
        return -1;
    }
    uint8_t c = src[st->pos];
    if (c == 123) {
        return jp_parse_object(src, st, max_nodes, kinds, vals, keys, firsts, nexts);
    }
    if (c == 91) {
        return jp_parse_array(src, st, max_nodes, kinds, vals, keys, firsts, nexts);
    }
    if (c == 34) {
        int64_t sh = jp_parse_string_hash(src, st);
        if (st->err != 0) return -1;
        return jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts, nexts,
                             JP_KIND_STR, sh);
    }
    if (c == 116) {
        if (st->pos + 4 <= st->len && src[st->pos + 1] == 114 &&
            src[st->pos + 2] == 117 && src[st->pos + 3] == 101) {
            st->pos += 4;
            return jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts,
                                 nexts, JP_KIND_BOOL, 1);
        }
        st->err = 15;
        return -1;
    }
    if (c == 102) {
        if (st->pos + 5 <= st->len && src[st->pos + 1] == 97 &&
            src[st->pos + 2] == 108 && src[st->pos + 3] == 115 &&
            src[st->pos + 4] == 101) {
            st->pos += 5;
            return jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts,
                                 nexts, JP_KIND_BOOL, 0);
        }
        st->err = 16;
        return -1;
    }
    if (c == 110) {
        if (st->pos + 4 <= st->len && src[st->pos + 1] == 117 &&
            src[st->pos + 2] == 108 && src[st->pos + 3] == 108) {
            st->pos += 4;
            return jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts,
                                 nexts, JP_KIND_NULL, 0);
        }
        st->err = 17;
        return -1;
    }
    if (c == 45 || (c >= 48 && c <= 57)) {
        int64_t nv = jp_parse_number(src, st);
        if (st->err != 0) return -1;
        return jp_alloc_node(st, max_nodes, kinds, vals, keys, firsts, nexts,
                             JP_KIND_NUM, nv);
    }
    st->err = 18;
    return -1;
}

static uint64_t jp_sum_tree(const int64_t *kinds, const int64_t *vals,
                            const int64_t *keys, const int64_t *firsts,
                            const int64_t *nexts, int64_t idx, int64_t depth,
                            uint64_t acc) {
    uint64_t h = jp_mix(acc, (uint64_t)kinds[idx]);
    h = jp_mix(h, (uint64_t)vals[idx]);
    h = jp_mix(h, (uint64_t)keys[idx]);
    h = jp_mix(h, (uint64_t)depth);
    int64_t child = firsts[idx];
    while (child >= 0) {
        h = jp_sum_tree(kinds, vals, keys, firsts, nexts, child, depth + 1, h);
        child = nexts[child];
    }
    return h;
}

static int64_t *jp_alloc_i64(int64_t n) {
    int64_t *p = (int64_t *)calloc((size_t)n, sizeof(int64_t));
    if (!p) abort();
    return p;
}

static uint64_t jp_bench(int64_t records, int64_t rounds) {
    ByteVec buf;
    buf.cap = records * 256;
    if (buf.cap < 256) buf.cap = 256;
    buf.data = (uint8_t *)malloc((size_t)buf.cap);
    if (!buf.data) abort();
    buf.len = 0;

    int64_t ver_pos = jp_build_corpus(&buf, records);
    int64_t max_nodes = records * 24 + 64;
    int64_t *kinds = jp_alloc_i64(max_nodes);
    int64_t *vals = jp_alloc_i64(max_nodes);
    int64_t *keys = jp_alloc_i64(max_nodes);
    int64_t *firsts = jp_alloc_i64(max_nodes);
    int64_t *nexts = jp_alloc_i64(max_nodes);

    uint64_t acc = JP_HASH_BASIS;
    for (int64_t round = 0; round < rounds; round++) {
        int64_t rval = round % 10000;
        buf.data[ver_pos] = (uint8_t)(48 + (rval / 1000));
        buf.data[ver_pos + 1] = (uint8_t)(48 + ((rval / 100) % 10));
        buf.data[ver_pos + 2] = (uint8_t)(48 + ((rval / 10) % 10));
        buf.data[ver_pos + 3] = (uint8_t)(48 + (rval % 10));

        ParserState st;
        st.pos = 0;
        st.len = buf.len;
        st.node_count = 0;
        st.err = 0;

        int64_t root = jp_parse_value(buf.data, &st, max_nodes, kinds, vals,
                                      keys, firsts, nexts);
        if (st.err != 0 || root < 0) {
            fprintf(stderr, "json parse failed\n");
            abort();
        }
        acc = jp_mix(acc, (uint64_t)st.node_count);
        acc = jp_sum_tree(kinds, vals, keys, firsts, nexts, root, 0, acc);
    }

    free(kinds);
    free(vals);
    free(keys);
    free(firsts);
    free(nexts);
    free(buf.data);
    return acc;
}

int main(int argc, char **argv) {
    int64_t records = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%" PRIu64 "\n", jp_bench(records, rounds));
    return 0;
}
