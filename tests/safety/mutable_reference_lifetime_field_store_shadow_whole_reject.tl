;; The whole-struct form of the shadowed-lifetime store is rejected (#8584).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: the local `a` shadows the lifetime `a`.
(define (store-whole [b : (&mut (RefBox a))]) : unit
  (let
    [a : i64 5]
    (set! (deref b) (RefBox (& a)))))

(define (main) : i64
  0)