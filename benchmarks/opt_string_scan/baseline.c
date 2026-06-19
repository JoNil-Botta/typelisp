#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int64_t scan_once(const char *text) {
    int64_t acc = 0;
    size_t n = strlen(text);
    for (size_t i = 0; i < n; i += 1) {
        if (text[i] == 'a') {
            acc += 3;
        } else if (text[i] == 'z') {
            acc += 7;
        } else {
            acc += 1;
        }
    }
    return acc;
}

static int64_t scan_repeat(const char *text, int64_t rounds) {
    int64_t acc = 0;
    for (int64_t i = 0; i < rounds; i += 1) {
        acc += scan_once(text);
    }
    return acc;
}

int main(int argc, char **argv) {
    const char *text = argc > 1 ? argv[1] : "";
    int64_t rounds = argc > 2 ? strtoll(argv[2], 0, 10) : 0;
    printf("%lld\n", (long long)scan_repeat(text, rounds));
    return 0;
}
