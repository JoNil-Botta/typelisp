;; Callee-owned storage cannot escape into a caller's dynamic array whose
;; element lifetime has the same name.
(define (store [a : i64] [items : (__tl_dyn-array (& a i64))]) : unit
  ; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
  (__tl_array-push! items (& a)))

(define (main) : i64
  0)