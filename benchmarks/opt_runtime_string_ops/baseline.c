#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *copy_range(const char *text, size_t start, size_t len) {
    char *out = (char *)malloc(len + 1);
    if (!out) {
        abort();
    }
    memcpy(out, text + start, len);
    out[len] = '\0';
    return out;
}

static char *concat2(const char *left, const char *right) {
    size_t left_len = strlen(left);
    size_t right_len = strlen(right);
    char *out = (char *)malloc(left_len + right_len + 1);
    if (!out) {
        abort();
    }
    memcpy(out, left, left_len);
    memcpy(out + left_len, right, right_len);
    out[left_len + right_len] = '\0';
    return out;
}

static int64_t string_ops_round(const char *text, const char *suffix, int64_t span) {
    size_t n = strlen(text);
    char *empty = copy_range(text, 0, 0);
    char *short_text = copy_range(text, 0, 4);
    char *tail = copy_range(text, n - (size_t)span, (size_t)span);
    char *left = concat2(empty, short_text);
    char *right = concat2(tail, suffix);
    char *joined = concat2(left, right);
    int64_t score = (int64_t)strlen(joined) + (int64_t)strlen(tail);

    free(empty);
    free(short_text);
    free(tail);
    free(left);
    free(right);
    free(joined);
    return score;
}

static int64_t string_ops_repeat(const char *text, const char *suffix, int64_t rounds) {
    int64_t acc = 0;
    for (int64_t i = 0; i < rounds; i += 1) {
        acc += string_ops_round(text, suffix, 48);
    }
    return acc;
}

int main(int argc, char **argv) {
    const char *text = argc > 1 ? argv[1] : "";
    const char *suffix = argc > 2 ? argv[2] : "";
    int64_t rounds = argc > 3 ? strtoll(argv[3], 0, 10) : 0;
    printf("%lld\n", (long long)string_ops_repeat(text, suffix, rounds));
    return 0;
}
