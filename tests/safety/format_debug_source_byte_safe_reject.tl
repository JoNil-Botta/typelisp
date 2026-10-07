;; A safe call of the raw format/format-debug-source-byte helper is rejected (#7700).
;; This check-only fixture must never execute.
(import stdlib.format)

(define (read-byte) : u8
  (format.format-debug-source-byte (ptr-null : (Ptr u8)) 0 (cast 0 : u8) false))

(define (main) : i64
  0)