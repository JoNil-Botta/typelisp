;; Callee-owned storage cannot escape through an array argument of a
;; constructor, next to a caller reference, into a caller lifetime with the
;; same name.
(defstruct ArrBox
  (:lifetimes a)
  (items (Array (& a i64) 2)))

; Must fail: `(& a)` borrows the parameter, not the caller's `a`.
(define (wrap [a : i64] [p : (& a i64)]) : (ArrBox a)
  (ArrBox (array p (& a))))

(define (main) : i64
  0)