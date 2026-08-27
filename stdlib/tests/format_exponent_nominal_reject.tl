(import stdlib.format)

(defstruct ExponentNominal
  (value i64))

(define (main) : i64
  (let
    [value : ExponentNominal (ExponentNominal 42)]
    [rendered : String (format.format "{:e}" value)]
    (cast (string-length rendered) : i64)))