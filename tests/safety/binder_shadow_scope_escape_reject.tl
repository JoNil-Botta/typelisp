;; A reference annotated with the binder cannot leave the binder scope
;; (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (f [y : (& r i64)]) : i64
  (let
    [w : i64 2]
    [out : (& w i64)
      (let
        [r : i64 1]
        [z : (& r i64) (& r)]
        z)]
    (deref out)))

(define (main) : i64
  0)