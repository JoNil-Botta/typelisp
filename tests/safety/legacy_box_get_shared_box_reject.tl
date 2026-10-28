(import stdlib.io)

(define (peek [b : (& b (Box i64))]) : i64
  (let
    [r (& (__tl-box-place b))]
    (deref r)))

(define (main) : i64
  (let
    [bx : (Box i64) (box 42)]
    (begin
      (io.println "peek=[{}]" (peek (& bx)))
      0)))