;; A safe call of the raw format/format-debug-bytes-core helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (render) : String
  (format.format-debug-bytes-core
    (ptr-null : (Ptr u8))
    1
    (cast 0 : u8)
    false
    (cast 34 : u8)))

(define (main) : i64
  0)