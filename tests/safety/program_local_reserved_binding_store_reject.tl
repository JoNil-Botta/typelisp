;; Visibility of the reserved target does not extend the shadowing local's life.
(define (probe [source : (& program str)]) : i64
  (let
    [saved source]
    (let
      [program : String (clone "local")]
      (set! saved (& program program)))
    0))

(define (main) : i64
  0)