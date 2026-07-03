(import stdlib.serialize)
(import "serialize_missing_extra_decls_hook_format.tl" module serialize_missing_extra_decls_hook_format as bad)
(import (serialize.serialize bad (Tuple i64 i64)) as tuple_ser)

(define (main) : i64
  0)