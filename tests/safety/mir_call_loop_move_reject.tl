;; A move inside a loop body reaches itself on the next iteration.
(define (consume [_text : String]) : i64
  1)

(define (repeat [text : String] [count : i64]) : i64
  (let
    [index : i64 0]
    [total : i64 0]
    (begin
      (while (< index count)
        (begin
          (set! total (+ total (consume text)))
          (set! index (+ index 1))))
      total)))

(define (main) : i64
  0)