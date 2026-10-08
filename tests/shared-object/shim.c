/* tests/shared-object/shim.c - the export of the shared-object dlopen test
 * (#8257). Every TypeLisp symbol in the DSO is hidden, so this shim, linked
 * into the same DSO, is its one default-visibility entry. It runs the
 * program's global initializers once, then calls the TypeLisp function.
 * #8194's export and lifecycle children replace this with the real contract. */
#include <pthread.h>

extern void tl_shared_object_init(void);
extern long _tl_worker_work(long seed);

static pthread_once_t typelisp_once = PTHREAD_ONCE_INIT;

static void typelisp_init(void) { tl_shared_object_init(); }

__attribute__((visibility("default"))) long typelisp_test_work(long seed) {
    pthread_once(&typelisp_once, typelisp_init);
    return _tl_worker_work(seed);
}
