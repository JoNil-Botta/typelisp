;; A `(& program T)` field accepts only a reference that lives as long as
;; `program`, so a returned aggregate cannot smuggle a parameter borrow out.
(defstruct Held
  (value (& program i64)))

(define (hold [n : i64]) : Held
  (Held (& n)))

(define (main) : i64
  (deref (hold 42).value))