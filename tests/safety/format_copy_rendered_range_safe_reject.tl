;; A safe call of the raw format/format-copy-rendered-range! helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (copy [text : (& text str)]) : unit
  (format.format-copy-rendered-range! text 0 (ptr-null : (MutPtr u8)) 0 1))

(define (main) : i64
  0)