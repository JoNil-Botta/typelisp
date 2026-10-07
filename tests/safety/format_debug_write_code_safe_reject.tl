;; A safe call of the raw format/format-debug-write-code! helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (write) : unit
  (format.format-debug-write-code! (ptr-null : (MutPtr u8)) 0 (cast 0 : u8)))

(define (main) : i64
  0)