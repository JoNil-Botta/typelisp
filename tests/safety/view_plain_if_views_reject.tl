;; A compound initializer consumes its selected Box even with two views (p25).
(defstruct Holder
  (b (Box i64))
  (c (Box i64)))

(define (select [r : (& r Holder)] [choose : bool]) : i64
  (let
    [b : (Box i64)
      (if choose
        r.b
        r.c)]
    (deref b)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42) (box 1))]
    (select (& holder) true)))