static long long calls;
static long long first(const void *text) { (void)text; ++calls; return 42; }
static long long second(const void *text) { (void)text; ++calls; return 1; }
long long (*tl_cfunc_borrow_first(void))(const void *) { return first; }
long long (*tl_cfunc_borrow_second(void))(const void *) { return second; }
long long tl_cfunc_borrow_calls(void) { return calls; }
