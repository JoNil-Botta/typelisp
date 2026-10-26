;; A zero-sized element store checks its bounds after the value's effects
;; (SPEC 5.10): the RHS prints before the out-of-bounds trap.
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