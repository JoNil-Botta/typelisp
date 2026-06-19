#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int is_sep(char c) {
    return c == '/' || c == '\\';
}

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

static char *path_join(const char *left, const char *right) {
    size_t left_len = strlen(left);
    size_t right_len = strlen(right);

    if (left_len == 0) {
        return copy_range(right, 0, right_len);
    }
    if (right_len == 0) {
        return copy_range(left, 0, left_len);
    }
    if (is_sep(left[left_len - 1])) {
        if (is_sep(right[0])) {
            return concat2(left, right + 1);
        }
        return concat2(left, right);
    }
    if (is_sep(right[0])) {
        return concat2(left, right);
    }

    char *left_slash = concat2(left, "/");
    char *joined = concat2(left_slash, right);
    free(left_slash);
    return joined;
}

static int64_t last_separator_index(const char *path) {
    int64_t last = -1;
    for (int64_t i = 0; path[i] != '\0'; i += 1) {
        if (is_sep(path[i])) {
            last = i;
        }
    }
    return last;
}

static char *dirname_copy(const char *path) {
    int64_t last = last_separator_index(path);
    if (last < 0) {
        return copy_range(".", 0, 1);
    }
    if (last == 0) {
        return copy_range("/", 0, 1);
    }
    return copy_range(path, 0, (size_t)last);
}

static char *basename_copy(const char *path) {
    int64_t last = last_separator_index(path);
    size_t n = strlen(path);
    if (last < 0) {
        return copy_range(path, 0, n);
    }
    return copy_range(path, (size_t)last + 1, n - ((size_t)last + 1));
}

static char *extension_copy(const char *path) {
    char *base = basename_copy(path);
    size_t n = strlen(base);
    int64_t dot = -1;

    for (int64_t i = 0; base[i] != '\0'; i += 1) {
        if (base[i] == '.') {
            dot = i;
        }
    }
    if (dot <= 0) {
        free(base);
        return copy_range("", 0, 0);
    }

    char *out = copy_range(base, (size_t)dot + 1, n - ((size_t)dot + 1));
    free(base);
    return out;
}

static int64_t path_helper_round(const char *root, const char *leaf) {
    char *joined = path_join(root, leaf);
    char *dir = dirname_copy(joined);
    char *base = basename_copy(joined);
    char *ext = extension_copy(joined);
    char *copy_name = concat2("copy-", base);
    char *copy_path = path_join(dir, copy_name);
    int64_t score = (int64_t)strlen(joined)
        + (int64_t)strlen(dir)
        + (int64_t)strlen(base)
        + (int64_t)strlen(ext)
        + (int64_t)strlen(copy_path);

    free(joined);
    free(dir);
    free(base);
    free(ext);
    free(copy_name);
    free(copy_path);
    return score;
}

static int64_t path_helper_repeat(const char *root, const char *leaf, int64_t rounds) {
    int64_t acc = 0;
    for (int64_t i = 0; i < rounds; i += 1) {
        acc += path_helper_round(root, leaf);
    }
    return acc;
}

int main(int argc, char **argv) {
    const char *root = argc > 1 ? argv[1] : ".";
    const char *leaf = argc > 2 ? argv[2] : "file.tl";
    int64_t rounds = argc > 3 ? strtoll(argv[3], 0, 10) : 0;
    printf("%lld\n", (long long)path_helper_repeat(root, leaf, rounds));
    return 0;
}
