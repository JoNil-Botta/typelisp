(import "stdlib/core_macros.tl" module stdlib.core-macros as core)

(define (stdlib-core-macros-api-fixture [flag : bool]) : unit
  (let
    [value : i64 0]
    (begin
      (core/when flag (set! value 1))
      (core/unless flag (set! value 2))
      unit)))