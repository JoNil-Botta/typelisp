static long long calls;
static long long gets;
static long long callback(long long value) { ++calls; return value + 1; }
long long (*tl_never_callback(void))(long long) { ++gets; return callback; }
long long tl_never_calls(void) { return calls; }
long long tl_never_gets(void) { return gets; }
