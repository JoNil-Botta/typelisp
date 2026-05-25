/* scripts/simd_cpuid_probe.c - print the host CPU's runnable SIMD ISAs.
 *
 * Prints one lowercase token per line for each ISA the *running* host can
 * actually execute (CPUID feature bit AND OS XSAVE enablement via XCR0):
 *   avx2      - AVX2 integer/FP, requires XMM+YMM state enabled
 *   avx512f   - AVX-512 Foundation, requires opmask+ZMM state enabled
 *
 * Used by scripts/detect-simd-isa.sh to gate SIMD *execution* tests on real
 * capability rather than host OS (refs #1147). Plain C, std headers only;
 * compiled on demand with the toolchain the test harness already requires
 * (clang on Windows, cc on Linux uses /proc/cpuinfo instead so this is only
 * built where needed).
 */
#include <stdint.h>
#include <stdio.h>

#if defined(_MSC_VER)
#include <intrin.h>
static void cpuid_count(int regs[4], int leaf, int subleaf) {
    __cpuidex(regs, leaf, subleaf);
}
static uint64_t xgetbv0(void) { return _xgetbv(0); }
#else
#include <cpuid.h>
static void cpuid_count(int regs[4], int leaf, int subleaf) {
    unsigned int a = 0, b = 0, c = 0, d = 0;
    __cpuid_count(leaf, subleaf, a, b, c, d);
    regs[0] = (int)a;
    regs[1] = (int)b;
    regs[2] = (int)c;
    regs[3] = (int)d;
}
static uint64_t xgetbv0(void) {
    unsigned int eax = 0, edx = 0;
    __asm__ volatile("xgetbv" : "=a"(eax), "=d"(edx) : "c"(0));
    return ((uint64_t)edx << 32) | eax;
}
#endif

int main(void) {
    int r0[4];
    cpuid_count(r0, 0, 0);
    int max_leaf = r0[0];

    int r1[4];
    cpuid_count(r1, 1, 0);
    int osxsave = (r1[2] >> 27) & 1; /* CPUID.1:ECX.OSXSAVE */
    uint64_t xcr0 = osxsave ? xgetbv0() : 0;

    /* XCR0: bit1 SSE/XMM, bit2 AVX/YMM, bit5 opmask, bit6 ZMM_Hi256, bit7 Hi16_ZMM. */
    int ymm_ok = osxsave && ((xcr0 & 0x6) == 0x6);
    int zmm_ok = osxsave && ((xcr0 & 0xe6) == 0xe6);

    if (max_leaf >= 7) {
        int r7[4];
        cpuid_count(r7, 7, 0);
        int avx2 = (r7[1] >> 5) & 1;      /* CPUID.7.0:EBX.AVX2 */
        int avx512f = (r7[1] >> 16) & 1;  /* CPUID.7.0:EBX.AVX512F */
        if (avx2 && ymm_ok) {
            printf("avx2\n");
        }
        if (avx512f && zmm_ok) {
            printf("avx512f\n");
        }
    }
    return 0;
}
