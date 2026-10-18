;; A borrow of the parameter `a` cannot reach the caller's `a` through a nested
;; constructor.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Outer
  (:lifetimes a)
  (inner (RefBox a)))

(define (store [a : i64] [b : (&mut a (Outer a))]) : unit
  ; Must fail: `(& a)` borrows the parameter.
  (set! (deref b) (Outer (RefBox (& a)))))

(define (main) : i64
  0)