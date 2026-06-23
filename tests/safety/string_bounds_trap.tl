;: SPEC safe-code contract: string indexing bounds traps instead of performing
;: invalid memory access.
(import "stdlib/string.tl")

(define (main) : i64
  (cast (string-ref "a" 1) : i64))