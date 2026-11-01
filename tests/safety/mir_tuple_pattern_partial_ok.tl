;; A by-value tuple pattern moves only the slots it binds by move: the slot
;; under `_` stays owned by the tuple and a later pattern may take it, and a
;; Copy slot stays readable.
(import stdlib.string)

(define (main) : i64
  (let
    [triple : (Tuple String String i64)
      (tuple (string.copy "ab") (string.copy "cde") 37)]
    [first : i64
      (match triple
        [(tuple text _ _) (string.string-length text)])]
    [second : i64
      (match triple
        [(tuple _ text _) (string.string-length text)])]
    (+ first (+ second (tuple-ref triple 2)))))