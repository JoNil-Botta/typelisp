;; A constructor argument holding a caller reference flows into a result whose
;; lifetime is a shorter-lived local spelled like the caller's lifetime, with
;; the arguments in either order.
(defstruct RefBox
  (:lifetimes t)
  (value (& t i64)))

(defstruct Two
  (:lifetimes s u)
  (boxed (& s (RefBox u)))
  (plain (& u i64)))

(defstruct Swapped
  (:lifetimes s u)
  (plain (& u i64))
  (boxed (& s (RefBox u))))

(define (boxed-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rb (RefBox (& (array-ref xs 0)))]
    [w (Two (& rb) (& a))]
    (deref w.plain)))

(define (plain-first [xs : (& a (Array i64 2))]) : i64
  (let
    [a : i64 0]
    [rb (RefBox (& (array-ref xs 0)))]
    [w (Swapped (& a) (& rb))]
    (deref w.plain)))

(define (main) : i64
  0)