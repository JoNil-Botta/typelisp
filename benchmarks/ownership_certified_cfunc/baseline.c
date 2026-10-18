typedef long long i64;
static i64 add(i64 a, i64 b) { return a + b; }
static i64 sub(i64 a, i64 b) { return a - b; }
static float mix(i64 a, float b, i64 c, float d) { return (float)(a + c) + b + d; }
static i64 sum9(i64 a, i64 b, i64 c, i64 d, i64 e, i64 f, i64 g, i64 h, i64 i) {
    return a + b + c + d + e + f + g + h + i;
}
typedef i64 (*binary)(i64, i64);
typedef float (*mixed)(i64, float, i64, float);
typedef i64 (*nine)(i64, i64, i64, i64, i64, i64, i64, i64, i64);
binary tl_certified_cfunc_add(void) { return add; }
binary tl_certified_cfunc_sub(void) { return sub; }
mixed tl_certified_cfunc_mix(void) { return mix; }
nine tl_certified_cfunc_sum9(void) { return sum9; }
