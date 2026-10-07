;; A safe call of the raw format/format-write-fill! helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (fill) : unit
  (format.format-write-fill! (ptr-null : (MutPtr u8)) 0 1 'x'))

(define (main) : i64
  0)