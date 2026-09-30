;: foreach-active is valid only directly inside a foreach gang.
(define (main) : i64
  (let
    [t : i64 0]
    (begin
      (foreach-active [lane : i64] (set! t 1))
      t)))