;; Bounded formatter adapters remain ordinary first-class function values.
(import stdlib.io)

(define (main) : i64
  (let
    [_write : (-> i64 String i64) io.format-stdout-write-raw]
    0))