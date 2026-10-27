;; Refs #9317: both descriptor code pointers must retain their definitions.
(define (main) : i64
  (let
    [x : i64 42]
    [f
      (lambda () : i64
        x)]
    [g
      (lambda () : i64
        x)]
    (if (= (f) (g))
      42
      1)))