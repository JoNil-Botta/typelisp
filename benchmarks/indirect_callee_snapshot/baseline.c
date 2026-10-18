static long long calls;
static long long gets;
static long long first(const void *text) { (void)text; ++calls; return 42; }
static long long second(const void *text) { (void)text; ++calls; return 1; }
long long (*tl_callee_first(void))(const void *) { ++gets; return first; }
long long (*tl_callee_second(void))(const void *) { ++gets; return second; }
long long tl_callee_calls(void) { return calls; }
long long tl_callee_gets(void) { return gets; }
