(import stdlib.io)

(define (poke! [b : (&mut b (Box i64))]) : unit
  (let
    [r (&mut (__tl-box-place b))]
    (set! (deref r) 43)))

(define (main) : i64
  (let
    [bx : (Box i64) (box 42)]
    (begin
      (poke! (&mut bx))
      (io.println "after=[{}]" (deref bx))
      0)))