typedef long long i64;
static i64 values[3] = {1, 41, 99};
static i64 calls;
static i64 answer(i64 x) { return x + 1; }
typedef i64 (*callback)(i64);
i64 *tl_certified_values(void) { return values; }
callback tl_certified_resolve(void) { ++calls; return answer; }
i64 tl_certified_resolve_count(void) { return calls; }
