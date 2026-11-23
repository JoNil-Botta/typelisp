/* Checked-reference load-GVN benchmark (#5201).
 * Both implementations may inline. The runtime shared field stays invariant
 * across writes through a disjoint exclusive pointer. Each iteration updates
 * the exclusive pair from its previous state, and main consumes both fields.
 */
#include <inttypes.h>
#include <stdio.h>

typedef struct BorrowedPair {
    uint64_t x;
    uint64_t y;
} BorrowedPair;

static void borrowed_disjoint_store_touch(BorrowedPair *write, uint64_t value) {
    write->y ^= write->x + value;
}

static void borrowed_disjoint_store_loop(
    const BorrowedPair *read,
    BorrowedPair *write,
    uint64_t iterations) {
    for (uint64_t i = 0; i < iterations; i++) {
        uint64_t current = read->x;
        borrowed_disjoint_store_touch(write, i + current);
        write->x = read->x + write->y;
    }
}

int main(int argc, char **argv) {
    (void)argv;
    BorrowedPair left = {16ULL + (uint64_t)argc, 0};
    BorrowedPair right = {23, 0};
    uint64_t iterations = 100000000ULL + (uint64_t)argc;
    uint64_t first_iterations = iterations / 2;
    uint64_t second_iterations = iterations - first_iterations;
    borrowed_disjoint_store_loop(&left, &right, first_iterations);
    borrowed_disjoint_store_loop(&left, &right, second_iterations);
    uint64_t checksum = right.x ^ right.y;
    printf("%" PRIu64 "\n", checksum);
    return (int)(checksum & 0xFFULL);
}
