;; #8998: storing a borrow of a self-named nominal carrier's own slot into
;; caller storage escapes the parameter's storage, though its type spells the
;; caller region.
(defstruct RefBox
  (:lifetimes a)
  (value (& a i64)))

(defstruct Outer
  (:lifetimes m)
  (inner (& m (RefBox m))))

; Must fail: `(& s)` borrows the parameter `s`, which dies at the return.
(define (slot [s : (RefBox s)] [o : (&mut s (Outer s))]) : unit
  (set! o.inner (& s)))

(define (main) : i64
  0)