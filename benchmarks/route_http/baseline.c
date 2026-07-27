/* benchmarks/route_http/baseline.c - clang C baseline for route_http.
 *
 * Equivalent to benchmarks/route_http/bench.tl: a route table is generated at
 * startup from static vocabulary data and a deterministic LCG, every route
 * being a sequence of two to four segments (literal word or `:param` wildcard)
 * plus a method bit mask (GET/POST/PUT/DELETE) and a handler id. Each round
 * assembles `requests` request paths from a 24-entry token vocabulary: roughly
 * 70% target a route picked from the table and 30% are arbitrary paths that
 * usually miss, and roughly 20% carry a query string the router has to strip.
 * Requests are routed by splitting on `/` and comparing literal segments
 * byte-for-byte, and each contribution folds into a rolling accumulator.
 *
 * TypeLisp `+`/`-`/`*` wrap modulo 2^64; the LCG products here are formed in
 * uint64_t so the C side wraps identically, and every other value in this
 * workload stays far inside 63 bits. The accumulator stays in [0, prime), so
 * the printed decimal matches TypeLisp's print of an i64.
 *
 * The one deliberate representation difference is path storage: TypeLisp
 * concatenates borrowed `String` pieces into a fresh arena `String` per
 * request, while C fills a reusable stack `char` buffer. Both then do the same
 * byte-level scanning and comparison over the assembled path.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define RT_MODULUS 1000000007LL
#define RT_VOCABULARY_COUNT 16
#define RT_JUNK_BASE 16
#define RT_JUNK_COUNT 8
#define RT_TOKEN_COUNT 24
#define RT_QUERY_COUNT 2
#define RT_MAX_SEGMENTS 4
#define RT_PATH_CAPACITY 128
/* Contribution of a request that no route accepts. */
#define RT_MISS_MARK 777767LL

/* The 16 words the route table's literal segments are drawn from. */
static const char *const rt_words[RT_VOCABULARY_COUNT] = {
    "users",  "posts",  "comments", "settings", "admin",   "api",
    "v1",     "v2",     "search",   "images",   "billing", "orders",
    "profile", "health", "metrics", "reports"
};

/* Request path segments, each already carrying its leading '/'. Entries 0-15
 * mirror the route vocabulary; entries 16-23 are words no route ever names, so
 * they only match wildcard segments. */
static const char *const rt_tokens[RT_TOKEN_COUNT] = {
    "/users",   "/posts",   "/comments",   "/settings", "/admin",
    "/api",     "/v1",      "/v2",         "/search",   "/images",
    "/billing", "/orders",  "/profile",    "/health",   "/metrics",
    "/reports", "/quux",    "/zzyzx",      "/frobnicate", "/wobble",
    "/xyzzy",   "/plugh",   "/grault",     "/thud"
};

static const char *const rt_queries[RT_QUERY_COUNT] = {
    "", "?page=2&sort=desc"
};

static int64_t rt_word_length[RT_VOCABULARY_COUNT];
static int64_t rt_token_length[RT_TOKEN_COUNT];
static int64_t rt_query_length[RT_QUERY_COUNT];

static int64_t rt_text_length(const char *text) {
    int64_t length = 0;
    while (text[length] != '\0') {
        length += 1;
    }
    return length;
}

static void rt_measure_static_text(void) {
    for (int64_t i = 0; i < RT_VOCABULARY_COUNT; i += 1) {
        rt_word_length[i] = rt_text_length(rt_words[i]);
    }
    for (int64_t i = 0; i < RT_TOKEN_COUNT; i += 1) {
        rt_token_length[i] = rt_text_length(rt_tokens[i]);
    }
    for (int64_t i = 0; i < RT_QUERY_COUNT; i += 1) {
        rt_query_length[i] = rt_text_length(rt_queries[i]);
    }
}

/* 64-bit LCG. The state advances over the full word and every drawn value comes
 * from the high bits, whose period is much longer than the low bits'. */
static int64_t rt_next_state(int64_t state) {
    return (int64_t)((uint64_t)state * 6364136223846793005ULL +
                     1442695040888963407ULL);
}

static int64_t rt_draw(int64_t state) {
    return (state >> 33) & 2147483647LL;
}

static void rt_build_table(int64_t *segment_kind, int64_t *segment_word,
                           int64_t *route_start, int64_t *route_length,
                           int64_t *route_mask, int64_t *route_handler,
                           int64_t routes) {
    int64_t state = 20250727;
    int64_t cursor = 0;
    for (int64_t r = 0; r < routes; r += 1) {
        state = rt_next_state(state);
        int64_t length = 2 + rt_draw(state) % 3;
        route_start[r] = cursor;
        route_length[r] = length;
        for (int64_t k = 0; k < length; k += 1) {
            state = rt_next_state(state);
            if (rt_draw(state) % 5 == 0) {
                segment_kind[cursor + k] = 1;
                segment_word[cursor + k] = 0;
            } else {
                segment_kind[cursor + k] = 0;
                segment_word[cursor + k] = rt_draw(state) % RT_VOCABULARY_COUNT;
            }
        }
        cursor = cursor + length;
        state = rt_next_state(state);
        route_mask[r] = 1 + rt_draw(state) % 15;
        route_handler[r] = r * 7 + 13;
    }
}

/* Match one route against path[0, path_end). Returns the rolling hash of the
 * wildcard captures on success and -1 on failure. The whole path must be
 * consumed, and a wildcard segment must capture at least one byte. */
static int64_t rt_match_route(const char *path, int64_t path_end,
                              const int64_t *segment_kind,
                              const int64_t *segment_word, int64_t base,
                              int64_t length) {
    int64_t pos = 0;
    int64_t k = 0;
    int ok = 1;
    int64_t hash = 0;
    while (k < length && ok) {
        if (pos >= path_end || path[pos] != '/') {
            ok = 0;
        } else {
            int64_t start = pos + 1;
            pos = start;
            while (pos < path_end && path[pos] != '/') {
                pos += 1;
            }
            int64_t span = pos - start;
            if (segment_kind[base + k] == 1) {
                if (span == 0) {
                    ok = 0;
                } else {
                    for (int64_t b = start; b < pos; b += 1) {
                        hash = (hash * 131 + (int64_t)path[b]) % RT_MODULUS;
                    }
                }
            } else {
                int64_t word = segment_word[base + k];
                if (span != rt_word_length[word]) {
                    ok = 0;
                } else {
                    int64_t b = 0;
                    while (b < span && ok) {
                        if (path[start + b] == rt_words[word][b]) {
                            b += 1;
                        } else {
                            ok = 0;
                        }
                    }
                }
            }
        }
        k += 1;
    }
    if (ok && pos == path_end) {
        return hash;
    }
    return -1;
}

static int64_t rt_route_request(const char *path, int64_t path_length,
                                int64_t method, const int64_t *segment_kind,
                                const int64_t *segment_word,
                                const int64_t *route_start,
                                const int64_t *route_length,
                                const int64_t *route_mask,
                                const int64_t *route_handler, int64_t routes) {
    int64_t path_end = path_length;
    int64_t scan = 0;
    int scanning = 1;
    int64_t captures = -1;
    int64_t handler = 0;
    while (scan < path_end && scanning) {
        if (path[scan] == '?') {
            path_end = scan;
            scanning = 0;
        } else {
            scan += 1;
        }
    }
    for (int64_t r = 0; r < routes && captures < 0; r += 1) {
        if ((route_mask[r] & method) != 0) {
            int64_t hash = rt_match_route(path, path_end, segment_kind,
                                          segment_word, route_start[r],
                                          route_length[r]);
            if (hash >= 0) {
                captures = hash;
                handler = route_handler[r];
            }
        }
    }
    if (captures < 0) {
        return RT_MISS_MARK;
    }
    return (handler * 1000003 + captures * 31 + method) % RT_MODULUS;
}

static int64_t rt_build_path(char *path, const int64_t *choice,
                             int64_t segments, int64_t query) {
    int64_t length = 0;
    for (int64_t k = 0; k < segments; k += 1) {
        int64_t token = choice[k];
        memcpy(path + length, rt_tokens[token], (size_t)rt_token_length[token]);
        length += rt_token_length[token];
    }
    memcpy(path + length, rt_queries[query], (size_t)rt_query_length[query]);
    length += rt_query_length[query];
    return length;
}

static int64_t *rt_alloc(int64_t count) {
    int64_t *items = (int64_t *)calloc((size_t)count + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static int64_t rt_bench(int64_t routes, int64_t requests, int64_t rounds) {
    int64_t *segment_kind = rt_alloc(routes * RT_MAX_SEGMENTS);
    int64_t *segment_word = rt_alloc(routes * RT_MAX_SEGMENTS);
    int64_t *route_start = rt_alloc(routes);
    int64_t *route_length = rt_alloc(routes);
    int64_t *route_mask = rt_alloc(routes);
    int64_t *route_handler = rt_alloc(routes);
    int64_t choice[RT_MAX_SEGMENTS] = { 0 };
    char path[RT_PATH_CAPACITY];
    int64_t state = 987654321;
    int64_t acc = 0;

    rt_measure_static_text();
    rt_build_table(segment_kind, segment_word, route_start, route_length,
                   route_mask, route_handler, routes);
    for (int64_t round = 0; round < rounds; round += 1) {
        for (int64_t i = 0; i < requests; i += 1) {
            int64_t method = 0;
            int64_t segments = 0;
            state = rt_next_state(state);
            if (rt_draw(state) % 10 < 7) {
                state = rt_next_state(state);
                int64_t route = rt_draw(state) % routes;
                int64_t base = route_start[route];
                segments = route_length[route];
                for (int64_t k = 0; k < segments; k += 1) {
                    if (segment_kind[base + k] == 1) {
                        state = rt_next_state(state);
                        choice[k] = RT_JUNK_BASE + rt_draw(state) % RT_JUNK_COUNT;
                    } else {
                        choice[k] = segment_word[base + k];
                    }
                }
                state = rt_next_state(state);
                method = (int64_t)1 << (rt_draw(state) % 4);
                while ((route_mask[route] & method) == 0) {
                    method = method << 1;
                    if (method > 8) {
                        method = 1;
                    }
                }
            } else {
                state = rt_next_state(state);
                segments = 2 + rt_draw(state) % 3;
                for (int64_t k = 0; k < segments; k += 1) {
                    state = rt_next_state(state);
                    choice[k] = rt_draw(state) % RT_TOKEN_COUNT;
                }
                state = rt_next_state(state);
                method = (int64_t)1 << (rt_draw(state) % 4);
            }
            state = rt_next_state(state);
            int64_t query = rt_draw(state) % 10 < 2 ? 1 : 0;
            int64_t path_length = rt_build_path(path, choice, segments, query);
            acc = (acc * 131 +
                   rt_route_request(path, path_length, method, segment_kind,
                                    segment_word, route_start, route_length,
                                    route_mask, route_handler, routes)) %
                  RT_MODULUS;
        }
    }
    free(segment_kind);
    free(segment_word);
    free(route_start);
    free(route_length);
    free(route_mask);
    free(route_handler);
    return acc;
}

int main(int argc, char **argv) {
    int64_t routes = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t requests = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    int64_t rounds = argc > 3 ? strtoll(argv[3], 0, 10) : 0;
    printf("%lld\n", (long long)rt_bench(routes, requests, rounds));
    return 0;
}
