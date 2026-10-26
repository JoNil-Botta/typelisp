;; A copyable payload bound from a view of an enum is a copy in the pattern
;; binder's own storage, so a borrow of it cannot be returned (#8889 review).
;; Rust: E0515 "cannot return reference to local variable `x`".
(defstruct C
  (k i64)
  (n i64)
  (m i64))

(defenum E
  (A C)
  (B i64))

(defstruct Out
  (e E)
  (s C))

(define (leak [p : (& p Out)]) : (& p C)
  (match p.e
    ; Must fail: `x` is a copy that dies with its arm.
    [(A x) (& x)]
    [(B _) (& p.s)]))

(define (main) : i64
  0)