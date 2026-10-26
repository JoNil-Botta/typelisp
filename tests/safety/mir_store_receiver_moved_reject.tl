;; The right-hand side moves the receiver's selected array away before the
;; store writes it (SPEC 5.10: it may grow or reassign its container but not
;; leave it moved).
(import stdlib.string)

(define (take [xs : (Array String 1)]) : i64
  0)

(define (pick [c : bool]) : i64
  (let
    [items : (Array String 1) (array "a")]
    [fixed : (Array String 1) (array "b")]
    (begin
      (set!
        (array-ref
          (if c
            items
            fixed)
          0)
        (begin
          (take items)
          "c"))
      0)))

(define (main) : i64
  (pick true))