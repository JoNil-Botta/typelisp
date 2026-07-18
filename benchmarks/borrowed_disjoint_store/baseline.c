/* Checked-reference load-GVN benchmark (#5201).
 *
 * Equivalent to bench.tl: read one Pair through a shared pointer, write a
 * distinct Pair through an exclusive pointer, then reread the shared Pair.
 */
#include <stdint.h>

typedef struct BorrowedPair {
    uint64_t x;
    uint64_t y;
} BorrowedPair;

__attribute__((noinline)) static void borrowed_disjoint_store_step(
    const BorrowedPair *read,
    BorrowedPair *write,
    uint64_t value) {
    uint64_t before = read->x;
    write->y = value;
    write->x = before + read->x;
}

int main(int argc, char **argv) {
    (void)argv;
    BorrowedPair left = {17, 0};
    BorrowedPair right = {23, 0};
    uint64_t iterations = 100000000ULL + (uint64_t)argc;
    uint64_t acc = 0;
    for (uint64_t i = 0; i < iterations; i++) {
        borrowed_disjoint_store_step(&left, &right, i);
        acc += right.x;
    }
    return (int)((acc + right.y) & 0xFFULL);
}
