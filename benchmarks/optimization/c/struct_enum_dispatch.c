#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct Pair {
    int64_t left;
    int64_t right;
} Pair;

typedef enum Op {
    OP_ADD,
    OP_MUL,
    OP_SUB
} Op;

static int64_t apply_op(Op op, Pair pair) {
    switch (op) {
    case OP_ADD:
        return pair.left + pair.right;
    case OP_MUL:
        return (pair.left * pair.right) % 1000000007LL;
    case OP_SUB:
        return pair.left - pair.right;
    }
    return 0;
}

static Op choose_op(int64_t i) {
    int64_t tag = i % 3;
    if (tag == 0) {
        return OP_ADD;
    }
    if (tag == 1) {
        return OP_MUL;
    }
    return OP_SUB;
}

static int64_t bench(int64_t n) {
    int64_t acc = 0;
    for (int64_t i = 0; i < n; i += 1) {
        Pair pair = { i, i + 1 };
        acc = (acc + apply_op(choose_op(i), pair)) % 1000000007LL;
    }
    return acc;
}

int main(int argc, char **argv) {
    int64_t n = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    printf("%lld\n", (long long)bench(n));
    return 0;
}
