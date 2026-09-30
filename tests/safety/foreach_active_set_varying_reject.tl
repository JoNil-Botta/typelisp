;: The body cannot write one lane of a varying gang local.
(define (main) : i64
  (begin
    (foreach
      ([i : i64 0 4])
      (let
        [v : i64 i]
        (foreach-active [lane : i64] (set! v 1))))
    0))