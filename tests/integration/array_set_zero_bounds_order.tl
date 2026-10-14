(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array unit 1) (array unit)]
    [index : i64 (string.>int (io.arg 1))]
    (begin
      (set!
        (array-ref items index)
        (begin
          (io.println "RHS ran")
          unit))
      0)))