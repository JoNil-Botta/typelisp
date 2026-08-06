;: A nested owner cannot be lengthened to an enclosing signature lifetime.
(define (main [anchor : (& outer i64)]) : i64
  (let
    [inner : i64 1]
    [short : (& inner i64) (& inner)]
    [too-long : (& outer i64) short]
    0))