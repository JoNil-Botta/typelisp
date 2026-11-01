;; Callee-owned storage cannot escape through box storage into a caller
;; lifetime with the same name.
(defstruct BoxBox
  (:lifetimes a)
  (boxed (Box (& a i64))))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (store [a : i64] [b : (&mut a (BoxBox a))]) : unit
  (set! b.boxed (box (& a))))

(define (main) : i64
  0)