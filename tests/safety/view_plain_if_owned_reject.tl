;; A view/owned compound initializer has no field/name exception (p26).
(defstruct Holder
  (b (Box i64)))

(define (select [r : (& r Holder)] [choose : bool]) : i64
  (let
    [b : (Box i64)
      (if choose
        r.b
        (box 1))]
    (deref b)))

(define (main) : i64
  (let
    [holder : Holder (Holder (box 42))]
    (select (& holder) true)))