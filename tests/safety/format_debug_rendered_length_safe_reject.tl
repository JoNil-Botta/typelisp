;; A safe call of the raw format/format-debug-rendered-length helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (count) : i64
  (format.format-debug-rendered-length
    (ptr-null : (Ptr u8))
    1
    (cast 0 : u8)
    false
    (cast 34 : u8)))

(define (main) : i64
  0)