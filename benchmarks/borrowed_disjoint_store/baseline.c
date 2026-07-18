/* Checked-reference load-GVN benchmark (#5201).
 *
 * Equivalent to bench.tl: repeatedly read one Pair through a shared pointer
 * while writing a distinct Pair through an exclusive pointer.
 */
#include <stdint.h>

typedef struct BorrowedPair {
    uint64_t x;
    uint64_t y;
} BorrowedPair;

__attribute__((noinline)) static uint64_t borrowed_disjoint_store_loop(
    const BorrowedPair *read,
    BorrowedPair *write,
    uint64_t iterations) {
    uint64_t acc = 0;
    for (uint64_t i = 0; i < iterations; i++) {
        write->y = i;
        write->x = read->x + i;
        acc += read->x;
    }
    return acc;
}

int main(int argc, char **argv) {
    (void)argv;
    BorrowedPair left = {17, 0};
    BorrowedPair right = {23, 0};
    uint64_t iterations = 100000000ULL + (uint64_t)argc;
    uint64_t first_iterations = iterations / 2;
    uint64_t second_iterations = iterations - first_iterations;
    uint64_t first = borrowed_disjoint_store_loop(
        &left, &right, first_iterations);
    uint64_t second = borrowed_disjoint_store_loop(
        &left, &right, second_iterations);
    return (int)((first + second) & 0xFFULL);
}
