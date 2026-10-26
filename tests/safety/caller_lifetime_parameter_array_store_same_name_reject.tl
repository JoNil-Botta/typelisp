;; Callee-owned storage cannot escape through array storage into a caller
;; lifetime with the same name.
(defstruct ArrBox
  (:lifetimes a)
  (items (Array (& a i64) 1)))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (store [a : i64] [b : (&mut a (ArrBox a))]) : unit
  (set! b.items (array (& a))))

(define (main) : i64
  0)