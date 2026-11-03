;; Returning the outer program reference must not hide the invalid inner store.
(define (probe [source : (& program str)]) : (& program str)
  (let
    [saved source]
    (let
      [program : String (clone "local")]
      (set! saved (& program program)))
    saved))

(define (main) : i64
  0)