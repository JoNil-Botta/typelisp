long long tl_certified_global_integer = 41;
float tl_certified_global_float = 42.75f;
static long long increment(long long value) { return value + 1; }
long long (*tl_certified_global_callback)(long long) = increment;
