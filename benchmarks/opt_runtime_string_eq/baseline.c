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

static int64_t score_bool(int value, int64_t score) {
    return value ? score : 0;
}

static int64_t string_eq_round(
    const char *text,
    const char *same,
    const char *first_mismatch,
    const char *late_mismatch,
    const char *empty,
    const char *short_text
) {
    int64_t acc = 0;
    acc += score_bool(strcmp(empty, "") == 0, 1);
    acc += score_bool(strcmp(short_text, short_text) == 0, 3);
    acc += score_bool(strcmp(text, same) == 0, 5);
    acc += score_bool(strcmp(text, first_mismatch) == 0, 7);
    acc += score_bool(strcmp(text, late_mismatch) == 0, 11);
    return acc;
}

static int64_t string_eq_repeat(const char *text, const char *short_text, int64_t rounds) {
    size_t n = strlen(text);
    char *empty = copy_range(text, 0, 0);
    char *same = concat2(text, empty);
    char *tail_after_first = copy_range(text, 1, n - 1);
    char *first_mismatch = concat2("!", tail_after_first);
    char *without_last = copy_range(text, 0, n - 1);
    char *late_mismatch = concat2(without_last, "!");
    int64_t acc = 0;

    for (int64_t i = 0; i < rounds; i += 1) {
        acc += string_eq_round(text, same, first_mismatch, late_mismatch, empty, short_text);
    }

    free(empty);
    free(same);
    free(tail_after_first);
    free(first_mismatch);
    free(without_last);
    free(late_mismatch);
    return acc;
}

int main(int argc, char **argv) {
    const char *text = argc > 1 ? argv[1] : "";
    const char *short_text = argc > 2 ? argv[2] : "";
    int64_t rounds = argc > 3 ? strtoll(argv[3], 0, 10) : 0;
    printf("%lld\n", (long long)string_eq_repeat(text, short_text, rounds));
    return 0;
}
