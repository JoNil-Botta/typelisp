;: SPEC safe-code contract: string indexing bounds traps instead of performing
;: invalid memory access.
;; lint-allow: unused-import
(import stdlib.string)

(define (main) : i64
  (cast (string-ref "a" 1) : i64))