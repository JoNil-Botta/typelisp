;; A safe call of the raw format/format-debug-write-byte! helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (write) : i64
  (format.format-debug-write-byte! (ptr-null : (MutPtr u8)) 0 (cast 0 : u8) 0))

(define (main) : i64
  0)