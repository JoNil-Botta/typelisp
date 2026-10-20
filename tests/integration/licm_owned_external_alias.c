#include <stdint.h>

/* The first word is the boxed record at opt0/1 and its descriptor at opt2.
   Both globals have the same length. Either representation becomes aliased. */
extern uintptr_t _tl_licm_owned_external_alias_reads;
extern uintptr_t _tl_licm_owned_external_alias_writes;

void alias_globals(void) {
    _tl_licm_owned_external_alias_writes = _tl_licm_owned_external_alias_reads;
}
