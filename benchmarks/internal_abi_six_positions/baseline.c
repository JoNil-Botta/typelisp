#include <stdint.h>

typedef struct { void *entry; void *environment; } Closure;
extern int64_t tl_abi_four(int64_t, double, int64_t, double);
extern int64_t tl_abi_five(int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t tl_abi_six(int64_t, int64_t, int64_t, int64_t, double, float);
extern int64_t tl_abi_eight(int64_t, double, int64_t, float, double, int64_t, int64_t, double);
extern void *tl_string_concat5(const void *, int64_t, const void *, int64_t, const void *, int64_t, const void *, int64_t, const void *, int64_t);
extern int64_t tl_tlci_call_macro_entry(int64_t, int64_t, int64_t, int64_t, int64_t, int64_t, int64_t);
extern int64_t tl_atomic_i64_load_ptr(int64_t *);
extern int64_t tl_atomic_i64_cas_ptr(int64_t *, int64_t, int64_t);
static volatile int64_t preserved = 1;

#ifdef _WIN32
/* Normal clang-generated C calls supply all GP/FP arguments. These naked
   Win64 interposers forward only stack words, install canaries immediately
   before the call, and inspect them before any compiler-generated reload.
   They restore their own caller's registers even when a tested callee fails. */
#define U __attribute__((unused))
#define COPY_WORD(from, to) "movq " #from "(%rsp), %r10\nmovq %r10, " #to "(%rsp)\n"
#define PROBE(frame, copies, call) \
    "pushq %rsi\npushq %rdi\nsubq $" #frame ", %rsp\n" copies \
    "movabsq $0x13579bdf2468ace, %rsi\nmovabsq $0x2468ace13579bdf, %rdi\n" call \
    "movabsq $0x13579bdf2468ace, %r10\ncmpq %r10, %rsi\njne 1f\n" \
    "movabsq $0x2468ace13579bdf, %r10\ncmpq %r10, %rdi\nje 2f\n" \
    "1: movq $0, preserved(%rip)\n2: addq $" #frame ", %rsp\npopq %rdi\npopq %rsi\nretq"
__attribute__((naked)) static int64_t call_four(int64_t a U, double b U, int64_t c U, double d U) {
    __asm__(PROBE(40, "", "callq tl_abi_four\n"));
}
__attribute__((naked)) static int64_t call_five(int64_t a U, int64_t b U, int64_t c U, int64_t d U, int64_t e U) {
    __asm__(PROBE(40, COPY_WORD(96, 32), "callq tl_abi_five\n"));
}
__attribute__((naked)) static int64_t call_six(int64_t a U, int64_t b U, int64_t c U, int64_t d U, double e U, float f U) {
    __asm__(PROBE(56, COPY_WORD(112, 32) COPY_WORD(120, 40), "callq tl_abi_six\n"));
}
__attribute__((naked)) static int64_t call_eight(int64_t a U, double b U, int64_t c U, float d U, double e U, int64_t f U, int64_t g U, double h U) {
    __asm__(PROBE(72, COPY_WORD(128, 32) COPY_WORD(136, 40) COPY_WORD(144, 48) COPY_WORD(152, 56), "callq tl_abi_eight\n"));
}
__attribute__((naked)) static void *call_concat5(const void *a U, int64_t al U, const void *b U, int64_t bl U, const void *c U, int64_t cl U, const void *d U, int64_t dl U, const void *e U, int64_t el U) {
    __asm__(PROBE(88, COPY_WORD(144, 32) COPY_WORD(152, 40) COPY_WORD(160, 48) COPY_WORD(168, 56) COPY_WORD(176, 64) COPY_WORD(184, 72), "callq tl_string_concat5\n"));
}
__attribute__((naked)) static int64_t call_macro(int64_t a U, int64_t b U, int64_t c U, int64_t d U, int64_t e U, int64_t f U, int64_t g U) {
    __asm__(PROBE(56, COPY_WORD(112, 32) COPY_WORD(120, 40) COPY_WORD(128, 48), "callq tl_tlci_call_macro_entry\n"));
}
__attribute__((naked)) static int64_t call_atomic_load(int64_t *ptr U) {
    __asm__(PROBE(40, "", "callq tl_atomic_i64_load_ptr\n"));
}
__attribute__((naked)) static int64_t call_atomic_cas(int64_t *ptr U, int64_t expected U, int64_t value U) {
    __asm__(PROBE(40, "", "callq tl_atomic_i64_cas_ptr\n"));
}
extern int64_t (*tl_thread_entry_ptr)(void *);
__attribute__((naked)) static int64_t call_thread(void *request U) {
    __asm__(PROBE(40, "", "callq *tl_thread_entry_ptr(%rip)\n"));
}
/* Independent Internal leaves force RSI/RDI clobbers regardless of the
   TypeLisp allocator's choices in the corresponding source functions. */
__attribute__((naked)) static int64_t internal_macro(void) {
    __asm__("movq %rcx, %rax\naddq %rdx, %rax\naddq %r8, %rax\n"
            "addq %r9, %rax\naddq %rsi, %rax\naddq %rdi, %rax\n"
            "xorq %rsi, %rsi\nxorq %rdi, %rdi\nretq");
}
__attribute__((naked)) static int64_t internal_thread(void) {
    __asm__("leaq 7(%rdx), %rax\nxorq %rsi, %rsi\nxorq %rdi, %rdi\nretq");
}
#else
#define call_four tl_abi_four
#define call_five tl_abi_five
#define call_six tl_abi_six
#define call_eight tl_abi_eight
#define call_concat5 tl_string_concat5
#define call_macro tl_tlci_call_macro_entry
#define call_atomic_load tl_atomic_i64_load_ptr
#define call_atomic_cas tl_atomic_i64_cas_ptr
#endif

int64_t tl_abi_c_exports(void) {
    int64_t small = call_four(1, 2.0, 3, 4.0);
    int64_t a = call_five(1, 2, 3, 4, 5);
    int64_t b = call_six(1, 2, 3, 4, 5.0, 6.0f);
    int64_t c = call_eight(1, 2.0, 3, 4.0f, 5.0, 6, 7, 8.0);
    int64_t value = 17;
    int64_t old = call_atomic_cas(&value, 17, 42);
    int64_t loaded = call_atomic_load(&value);
    return preserved && small == 10 && a == 15 && b == 21 && c == 36 && old == 17 && loaded == 42;
}
void *tl_abi_c_concat5(const void *a, int64_t al, const void *b, int64_t bl, const void *c, int64_t cl, const void *d, int64_t dl, const void *e, int64_t el) {
    return call_concat5(a, al, b, bl, c, cl, d, dl, e, el);
}
int64_t tl_abi_c_preserved(void) { return preserved; }
int64_t tl_abi_c_touch(int64_t value) { return value + 1; }
int64_t tl_abi_c_entry(Closure *callback) { return (int64_t)(uintptr_t)callback->entry; }
int64_t tl_abi_c_macro(Closure *callback) {
    int64_t result = call_macro((int64_t)(uintptr_t)callback->entry, 11, 12, 13, 14, 15, 16);
    if (result != 70 || !preserved) return 0;
#ifdef _WIN32
    result = call_macro((int64_t)(uintptr_t)internal_macro, 11, 12, 13, 14, 15, 16);
    if (result != 81 || !preserved) return 0;
#endif
    return 1;
}
int64_t tl_abi_c_thread(Closure *callback) {
#ifdef _WIN32
    int64_t result = 0;
    int32_t complete = 0;
    struct { Closure *callback; int64_t argument; int64_t *result; int32_t *complete; }
        request = { callback, 35, &result, &complete };
    uintptr_t old_arena;
    __asm__ volatile("movq %%gs:0x28, %0" : "=r"(old_arena));
    call_thread(&request);
    if (result != 42 || complete != 1) preserved = 0;
    Closure forced = { (void *)internal_thread, 0 };
    request.callback = &forced;
    result = 0;
    complete = 0;
    call_thread(&request);
    __asm__ volatile("movq %0, %%gs:0x28" : : "r"(old_arena) : "memory");
    return result == 42 && complete == 1 && preserved;
#else
    (void)callback;
    return 1;
#endif
}
