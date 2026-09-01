(import stdlib.serialize)

;; lint-allow: unused-import
(import serialize_missing_extra_decls_hook_format as bad)
(import (serialize.serialize bad char) as char_ser)

(define (main) : i64
  0)