/* benchmarks/opt_bytecode_vm/baseline.c - clang C baseline for opt_bytecode_vm.
 *
 * Equivalent to benchmarks/opt_bytecode_vm/bench.tl: runs a small fixed
 * stack-machine program many rounds with a round-dependent input and folds each
 * run's result into a wrapping accumulator. Every value is reduced modulo a
 * prime so it stays non-negative and the printed decimal matches TypeLisp.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#define VM_PRIME 1000000007LL

enum Op {
    OP_PUSH_INPUT,
    OP_PUSH_CONST,
    OP_DUP,
    OP_ADD,
    OP_MUL,
    OP_XOR
};

typedef struct Inst {
    int tag;
    int64_t operand;
} Inst;

static int64_t vm_build_program(Inst *program) {
    program[0] = (Inst){ OP_PUSH_INPUT, 0 };
    program[1] = (Inst){ OP_PUSH_CONST, 1000003 };
    program[2] = (Inst){ OP_MUL, 0 };
    program[3] = (Inst){ OP_PUSH_CONST, 98765 };
    program[4] = (Inst){ OP_ADD, 0 };
    program[5] = (Inst){ OP_DUP, 0 };
    program[6] = (Inst){ OP_MUL, 0 };
    program[7] = (Inst){ OP_PUSH_CONST, 54321 };
    program[8] = (Inst){ OP_XOR, 0 };
    return 9;
}

static int64_t vm_run(const Inst *program, int64_t plen, int64_t *stack, int64_t input) {
    int64_t sp = 0;
    for (int64_t pc = 0; pc < plen; pc += 1) {
        switch (program[pc].tag) {
        case OP_PUSH_INPUT:
            stack[sp] = input;
            sp += 1;
            break;
        case OP_PUSH_CONST:
            stack[sp] = program[pc].operand;
            sp += 1;
            break;
        case OP_DUP:
            stack[sp] = stack[sp - 1];
            sp += 1;
            break;
        case OP_ADD: {
            int64_t b = stack[sp - 1];
            int64_t a = stack[sp - 2];
            stack[sp - 2] = (a + b) % VM_PRIME;
            sp -= 1;
            break;
        }
        case OP_MUL: {
            int64_t b = stack[sp - 1];
            int64_t a = stack[sp - 2];
            stack[sp - 2] = (a * b) % VM_PRIME;
            sp -= 1;
            break;
        }
        case OP_XOR: {
            int64_t b = stack[sp - 1];
            int64_t a = stack[sp - 2];
            stack[sp - 2] = (a ^ b) % VM_PRIME;
            sp -= 1;
            break;
        }
        }
    }
    return stack[0];
}

static int64_t vm_bench(int64_t rounds) {
    Inst program[9];
    int64_t plen = vm_build_program(program);
    int64_t stack[64];
    int64_t acc = 0;
    for (int64_t round = 0; round < rounds; round += 1) {
        int64_t input = (round * 2654435761LL + 12345LL) % VM_PRIME;
        acc = (acc + vm_run(program, plen, stack, input)) % VM_PRIME;
    }
    return acc;
}

int main(int argc, char **argv) {
    int64_t rounds = argc > 1 ? strtoll(argv[1], 0, 10) : 0;
    printf("%lld\n", (long long)vm_bench(rounds));
    return 0;
}
