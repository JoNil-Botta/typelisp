;; #8998: a borrow of a self-named nominal carrier's own slot is the parameter's
;; storage, which dies at the return, though its type spells the caller region.
(defstruct Hold
  (:lifetimes p)
  (value (& p i64)))

; Must fail: `(& p)` borrows the parameter `p`.
(define (slot [p : (Hold p)]) : (& p (Hold p))
  (& p))

(define (main) : i64
  0)