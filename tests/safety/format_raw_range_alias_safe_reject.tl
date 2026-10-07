;; Importing stdlib.format under an alias does not launder its raw range
;; helpers into safe calls (#7700). This check-only fixture must never execute.
(import stdlib.format as fmt)

(define (fill) : unit
  (fmt.format-write-fill! (ptr-null : (MutPtr u8)) 0 1 'x'))

(define (main) : i64
  0)