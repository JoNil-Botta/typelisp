;; A by-value parameter named like the referent's lifetime shadows it too: its
;; borrow dies when `store` returns, so it may not be stored through `&mut`
;; into the caller's `a` field, whichever parameter comes first (#8584).
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

; Must fail: the parameter `a` shadows the lifetime `a`.
(define (store [a : i64] [b : (&mut (RefBox a))]) : unit
  (set! b.value (& a)))

(define (main) : i64
  0)