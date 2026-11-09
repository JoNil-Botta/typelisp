;; Genuine caller data keeps its lifetime under a binder of the same name
;; (#9609). The store follows the binder scope.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [b : (&mut r (RefBox r))] [p : (& r i64)]) : unit
  (let
    [q : i64 0]
    (let
      [r : i64 1]
      (let
        [alias : (& r i64) p]
        unit))
    (set! b.value p)))

(define (main) : i64
  0)