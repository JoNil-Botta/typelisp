(import stdlib.result)
(import (result.result i64 i64) as res)

(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (risky [ok : bool]) : res.Result
  (if ok
    (res.ok 1)
    (res.err 2)))

;; `try` may leave the function, but it may also continue, so the arm is not
;; diverging and its move must still reach the join.
(define (pick [flag : bool]) : res.Result
  (let
    [t : Token (Token 41 "t")]
    (begin
      (if flag
        (let
          [kept : i64 (+ (consume t) (try (risky true)))]
          unit)
        unit)
      (res.ok (consume t)))))

(define (main) : i64
  (res.value-or (pick false) 0))