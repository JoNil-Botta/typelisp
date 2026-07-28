/* benchmarks/phys_nbody/baseline.c - clang C baseline for phys_nbody.
 *
 * Equivalent to benchmarks/phys_nbody/bench.tl: bodies live in a square world
 * and are integrated with explicit Euler steps. Each round accumulates pairwise
 * softened gravitational accelerations into ax/ay, integrates velocity and
 * position, reflects bodies off the four walls with branchy clamps, and folds a
 * modular digest of every position and velocity into a rolling accumulator.
 *
 * All state is i64 fixed point with 20 fractional bits (Q44.20, one unit =
 * 1/1048576). The world is 1024 by 1024 units, softening holds the effective
 * distance at or above 8 units, and the timestep is 1/64. Fixed point is used
 * instead of double because clang's default
 * floating-point contraction fuses multiply-add pairs, which would make the
 * printed digest differ from TypeLisp's. TypeLisp `+`/`-`/`*` wrap modulo 2^64,
 * so every product here is formed in uint64_t and reinterpreted as int64_t,
 * which reproduces that wrapping exactly and keeps the C side free of signed
 * overflow. The value ranges of this workload keep every intermediate well
 * inside 63 bits, so no wrap is actually reached. `>>` on a negative int64_t is
 * an arithmetic shift under clang, matching TypeLisp's `shr` on i64, and `/`
 * and `%` truncate toward zero in both languages. The accumulator stays in
 * [0, prime), so the printed decimal matches TypeLisp's print of an i64.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define NB_MODULUS 1000000007LL
#define NB_FP_SHIFT 20
#define NB_FP_ONE 1048576LL
/* 1024.0 in Q44.20: the world is a NB_WORLD by NB_WORLD square. */
#define NB_WORLD 1073741824LL
/* 64.0 in Q44.20 of squared softening, so the softened distance is at least 8. */
#define NB_SOFT2 67108864LL
/* 16384.0 in Q44.20. */
#define NB_GRAVITY 17179869184LL
/* 1/64 in Q44.20. */
#define NB_DT 16384LL
#define NB_SQRT_ITERATIONS 40

/* Wrapping 64-bit product, matching TypeLisp's i64 `*`. */
static int64_t nb_wrap_mul(int64_t a, int64_t b) {
    return (int64_t)((uint64_t)a * (uint64_t)b);
}

/* Fixed-point multiply: the raw product wraps modulo 2^64, then an arithmetic
 * shift removes the duplicated fractional bits. */
static int64_t nb_mul(int64_t a, int64_t b) {
    return nb_wrap_mul(a, b) >> NB_FP_SHIFT;
}

/* Wrapping left shift by the fixed-point scale, matching TypeLisp's i64 `shl`. */
static int64_t nb_wrap_shl(int64_t a) {
    return (int64_t)((uint64_t)a << NB_FP_SHIFT);
}

/* Fixed-point divide. Callers guarantee a non-zero divisor. */
static int64_t nb_div(int64_t a, int64_t b) {
    return nb_wrap_shl(a) / b;
}

/* Integer floor-sqrt by Newton iteration from a bit-length seed. The seed is a
 * power of two at or above sqrt(n), so the iterates decrease monotonically and
 * the first non-decreasing step is the floor. */
static int64_t nb_isqrt(int64_t n) {
    if (n <= 0) {
        return 0;
    }
    int64_t bits = 0;
    int64_t probe = n;
    while (probe > 0) {
        probe >>= 1;
        bits += 1;
    }
    int64_t guess = (int64_t)1 << ((bits + 1) / 2);
    int64_t iteration = 0;
    int settled = 0;
    while (iteration < NB_SQRT_ITERATIONS && !settled) {
        int64_t next = (guess + n / guess) / 2;
        if (next >= guess) {
            settled = 1;
        } else {
            guess = next;
        }
        iteration += 1;
    }
    return guess;
}

/* Fixed-point sqrt: sqrt(v / 2^20) * 2^20 is floor-sqrt of (v << 20). */
static int64_t nb_sqrt(int64_t value) {
    return nb_isqrt(nb_wrap_shl(value));
}

/* 64-bit LCG. The state advances over the full word and every drawn value comes
 * from the high bits, whose period is much longer than the low bits'. */
static int64_t nb_next_state(int64_t state) {
    return (int64_t)((uint64_t)nb_wrap_mul(state, 6364136223846793005LL) +
                     1442695040888963407ULL);
}

static int64_t nb_draw(int64_t state) {
    return (state >> 33) & 2147483647LL;
}

static int64_t nb_seed(int64_t *px, int64_t *py, int64_t *vx, int64_t *vy,
                       int64_t *mass, int64_t n, int64_t seed) {
    int64_t state = seed;
    for (int64_t i = 0; i < n; i += 1) {
        state = nb_next_state(state);
        px[i] = nb_draw(state) % NB_WORLD;
        state = nb_next_state(state);
        py[i] = nb_draw(state) % NB_WORLD;
        state = nb_next_state(state);
        vx[i] = nb_draw(state) % 16777216LL - 8388608LL;
        state = nb_next_state(state);
        vy[i] = nb_draw(state) % 16777216LL - 8388608LL;
        state = nb_next_state(state);
        mass[i] = NB_FP_ONE + nb_draw(state) % 8388608LL;
    }
    return state;
}

static void nb_forces(const int64_t *px, const int64_t *py, const int64_t *mass,
                      int64_t *ax, int64_t *ay, int64_t n) {
    for (int64_t i = 0; i < n; i += 1) {
        int64_t sum_x = 0;
        int64_t sum_y = 0;
        for (int64_t j = 0; j < n; j += 1) {
            if (j != i) {
                int64_t dx = px[j] - px[i];
                int64_t dy = py[j] - py[i];
                int64_t d2 = nb_mul(dx, dx) + nb_mul(dy, dy) + NB_SOFT2;
                int64_t dist = nb_sqrt(d2);
                int64_t unit_x = nb_div(dx, dist);
                int64_t unit_y = nb_div(dy, dist);
                int64_t pull = nb_div(nb_mul(NB_GRAVITY, mass[j]), d2);
                sum_x = sum_x + nb_mul(pull, unit_x);
                sum_y = sum_y + nb_mul(pull, unit_y);
            }
        }
        ax[i] = sum_x;
        ay[i] = sum_y;
    }
}

static void nb_integrate(int64_t *px, int64_t *py, int64_t *vx, int64_t *vy,
                         const int64_t *ax, const int64_t *ay, int64_t n) {
    for (int64_t i = 0; i < n; i += 1) {
        int64_t nvx = vx[i] + nb_mul(ax[i], NB_DT);
        int64_t nvy = vy[i] + nb_mul(ay[i], NB_DT);
        int64_t npx = px[i] + nb_mul(nvx, NB_DT);
        int64_t npy = py[i] + nb_mul(nvy, NB_DT);
        if (npx < 0) {
            npx = -npx;
            nvx = -nvx;
        }
        if (npx > NB_WORLD) {
            npx = 2 * NB_WORLD - npx;
            nvx = -nvx;
        }
        if (npx < 0) {
            npx = 0;
        }
        if (npx > NB_WORLD) {
            npx = NB_WORLD;
        }
        if (npy < 0) {
            npy = -npy;
            nvy = -nvy;
        }
        if (npy > NB_WORLD) {
            npy = 2 * NB_WORLD - npy;
            nvy = -nvy;
        }
        if (npy < 0) {
            npy = 0;
        }
        if (npy > NB_WORLD) {
            npy = NB_WORLD;
        }
        vx[i] = nvx;
        vy[i] = nvy;
        px[i] = npx;
        py[i] = npy;
    }
}

/* Velocities are signed, so the remainder is normalized into [0, prime). */
static int64_t nb_fold(int64_t value) {
    return (value % NB_MODULUS + NB_MODULUS) % NB_MODULUS;
}

static int64_t nb_checksum(const int64_t *px, const int64_t *py,
                           const int64_t *vx, const int64_t *vy, int64_t n) {
    int64_t sum = 0;
    for (int64_t i = 0; i < n; i += 1) {
        sum = (sum + nb_fold(px[i])) % NB_MODULUS;
        sum = (sum + nb_fold(py[i])) % NB_MODULUS;
        sum = (sum + nb_fold(vx[i])) % NB_MODULUS;
        sum = (sum + nb_fold(vy[i])) % NB_MODULUS;
    }
    return sum;
}

static int64_t *nb_alloc(int64_t n) {
    int64_t *items = (int64_t *)calloc((size_t)n + 1, sizeof(int64_t));
    if (!items) {
        abort();
    }
    return items;
}

static int64_t nb_bench(int64_t n, int64_t rounds) {
    int64_t *px = nb_alloc(n);
    int64_t *py = nb_alloc(n);
    int64_t *vx = nb_alloc(n);
    int64_t *vy = nb_alloc(n);
    int64_t *ax = nb_alloc(n);
    int64_t *ay = nb_alloc(n);
    int64_t *mass = nb_alloc(n);
    int64_t acc = 0;
    nb_seed(px, py, vx, vy, mass, n, 1);
    for (int64_t round = 0; round < rounds; round += 1) {
        nb_forces(px, py, mass, ax, ay, n);
        nb_integrate(px, py, vx, vy, ax, ay, n);
        acc = (acc * 31 + nb_checksum(px, py, vx, vy, n)) % NB_MODULUS;
    }
    free(px);
    free(py);
    free(vx);
    free(vy);
    free(ax);
    free(ay);
    free(mass);
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)nb_bench(n, rounds));
    return 0;
}
