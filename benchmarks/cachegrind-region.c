/* Cachegrind measured-region entry for independently compiled C baselines.
 *
 * The harness renames each baseline's `main` to the symbol below, starts
 * Cachegrind instrumentation at the language-level entry boundary, and leaves
 * it enabled through process exit. Dynamic loader and PIE startup therefore do
 * not participate in exact benchmark/c instruction rows.
 */
#include <valgrind/cachegrind.h>

#undef main
extern int typelisp_instruction_count_benchmark_main(int argc, char **argv);

int main(int argc, char **argv) {
    CACHEGRIND_START_INSTRUMENTATION;
    return typelisp_instruction_count_benchmark_main(argc, argv);
}
