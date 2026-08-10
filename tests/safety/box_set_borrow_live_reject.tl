(define (take [_value : (& cell i64)]) : i64
  1)

(define (main) : i64
  (let
    [cell : (Box i64) (box 1)]
    [borrowed : (& cell i64) (& (__tl-box-place cell))]
    (begin
      (set! (deref cell) 2)
      (take borrowed))))