;; A stack pair read at a depth taken from the command line. At opt 2
;; bounds_group guards `sp - 1` and `sp - 2` with one unsigned test against the
;; literal length, and its slow arm replays both checks in order. Out of range,
;; the first failing member still aborts at its own site (#8258).
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [stack : (Array i64 2) (array 20 22)]
    [sp : i64 (string.>int (io.arg 1))]
    [b : i64 (array-ref stack (- sp 1))]
    [a : i64 (array-ref stack (- sp 2))]
    (+ a b)))