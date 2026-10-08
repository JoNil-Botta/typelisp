/* tests/shared-object/driver.c - host of the shared-object dlopen test
 * (#8257). It loads the DSO built from worker.tl and shim.c, then calls the
 * test export from two threads at once, repeatedly. Each thread allocates
 * through its own TypeLisp arena in the TLS block the dynamic loader gave the
 * DSO. Every result must match the value computed here; exits 0 when all do. */
#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>

typedef long (*work_fn)(long);

static work_fn work;

static long digits(long value) {
    long count = 1;
    while (value >= 10) {
        value /= 10;
        count++;
    }
    return count;
}

static long expected(long seed) {
    long total = 0;
    for (long i = 0; i < 2000; i++) {
        total += digits(seed + i) + 4;
    }
    return total;
}

static void *run(void *arg) {
    long seed = (long)arg;
    long want = expected(seed);
    for (int round = 0; round < 50; round++) {
        if (work(seed) != want) {
            return (void *)1;
        }
    }
    return (void *)0;
}

int main(int argc, char **argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: driver LIBRARY\n");
        return 2;
    }
    void *library = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
    if (library == NULL) {
        fprintf(stderr, "dlopen: %s\n", dlerror());
        return 1;
    }
    work = (work_fn)dlsym(library, "typelisp_test_work");
    if (work == NULL) {
        fprintf(stderr, "dlsym: %s\n", dlerror());
        return 1;
    }
    pthread_t threads[2];
    for (long t = 0; t < 2; t++) {
        if (pthread_create(&threads[t], NULL, run, (void *)(995 + t * 9000)) != 0) {
            return 1;
        }
    }
    int failed = 0;
    for (int t = 0; t < 2; t++) {
        void *result;
        pthread_join(threads[t], &result);
        failed |= result != (void *)0;
    }
    if (failed) {
        fprintf(stderr, "shared-object worker returned a wrong result\n");
        return 1;
    }
    printf("ok\n");
    return 0;
}
