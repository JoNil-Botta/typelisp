;; A local named like the referent's lifetime parameter shadows it: a borrow
;; of that local carries the name `a` but dies when `store` returns, so it may
;; not be stored through `&mut` into the caller's `a` field (#8584).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: the local `a` shadows the lifetime `a`.
(define (store [b : (&mut (RefBox a))]) : unit
  (let
    [a : i64 5]
    (set! b.value (& a))))

(define (main) : i64
  0)