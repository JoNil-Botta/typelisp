;; A scalar element store checks its bounds after the value's effects
;; (SPEC 5.10): the RHS prints before the out-of-bounds trap.
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [items : (Array i64 1) (array 10)]
    [index : i64 (string.>int (io.arg 1))]
    (begin
      (set!
        (array-ref items index)
        (begin
          (io.println "RHS ran")
          99))
      0)))