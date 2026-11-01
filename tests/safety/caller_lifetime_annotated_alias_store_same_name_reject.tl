;; An annotation names its lexical owner: here the parameter `a`.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(define (store [a : i64] [b : (&mut a (RefBox a))]) : unit
  (let
    [r : (& a i64) (& a)]
    ; Must fail: `r` borrows the parameter, not the caller's `a`.
    (set! b.value r)))

(define (main) : i64
  0)