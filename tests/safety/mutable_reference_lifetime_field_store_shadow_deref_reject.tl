;; The deref and whole-struct forms of the shadowed-lifetime store are rejected
;; like the dotted one (#8584).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: the local `a` shadows the lifetime `a`.
(define (store-deref [b : (&mut (RefBox a))]) : unit
  (let
    [a : i64 5]
    (set! (deref b).value (& a))))

(define (main) : i64
  0)