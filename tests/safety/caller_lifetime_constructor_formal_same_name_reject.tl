;; A constructor formal spelled like a by-value parameter still infers from a
;; borrow of that parameter: the result holds the parameter's own storage and
;; cannot be returned under a caller lifetime (#8998).
(defstruct Holder
  (:lifetimes cwd)
  (value (& cwd i64)))

; Must fail: `(& cwd)` borrows the parameter, which dies at the return.
(define (leak [cwd : i64] [_caller : (& next-cwd i64)]) : (Holder next-cwd)
  (Holder (& cwd)))

(define (main) : i64
  0)