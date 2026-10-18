#include <stdint.h>

/* Named TypeLisp function values carry an entry and an environment word. */
typedef struct {
    int64_t (*entry)(void *);
    void *environment;
} Callback;
static Callback *saved;
int64_t tl_test_callback_invoke(Callback *callback) {
    return callback->entry(callback->environment);
}
int64_t tl_test_callback_save(Callback *callback) {
    saved = callback;
    return 0;
}
int64_t tl_test_callback_invoke_saved(void) {
    return saved->entry(saved->environment);
}
extern int64_t tl_test_callback_increment(void);
int64_t tl_test_callback_invoke_exported(void) {
    return tl_test_callback_increment();
}
