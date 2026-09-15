#include <stdint.h>

/* Native C provider for typed code-pointer persistence on both x86-64 ABIs. */
typedef int64_t (*CFunction)(int64_t);
typedef struct { CFunction entry; } Table;
static int64_t resolve_count;
static int64_t add_one(int64_t value) { return value + 1; }
CFunction tl_cfn_entry = add_one;
CFunction tl_cfn_resolve(void) {
    ++resolve_count;
    return add_one;
}
int64_t tl_cfn_resolve_count(void) { return resolve_count; }
int64_t tl_cfn_table_score(Table table) { return table.entry(41); }
