;; A reference to callee-owned storage cannot be returned under a caller
;; lifetime with the same name.
; Must fail: `(& a)` borrows the parameter, not the caller's `a` of `p`.
(define (leak [a : i64] [p : (& a i64)]) : (& a i64)
  (& a))

(define (main) : i64
  0)