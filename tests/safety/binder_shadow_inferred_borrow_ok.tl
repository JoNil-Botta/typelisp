;; A borrow of the binder and its annotated alias share the spelling and stay
;; accepted (#9609).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defenum Opt
  (:lifetimes a)
  (None)
  (Some (& a i64)))

(define (f [y : (& r i64)]) : i64
  (let
    [r : i64 1]
    [t (& r)]
    [z : (& r i64) (& r)]
    (set! t z)
    (deref t)))

(define (main) : i64
  0)