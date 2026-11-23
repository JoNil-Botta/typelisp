;; Returning the outer program reference must not hide the invalid inner store.
(import stdlib.string)

(define (probe [source : (& program str)]) : (& program str)
  (let
    [saved source]
    (let
      [program : String (string.copy (& "local"))]
      (set! saved (& program program)))
    saved))

(define (main) : i64
  0)