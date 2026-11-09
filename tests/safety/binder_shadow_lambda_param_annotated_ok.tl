;; A lambda parameter annotated under a binder of that name is the lambda's
;; own lifetime (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (f [x : (& q i64)] [y : (& r i64)]) : i64
  (let
    [r : i64 1]
    [g
      (lambda ([z : (& r i64)]) : i64
        (deref z))]
    (g x)))

(define (main) : i64
  0)