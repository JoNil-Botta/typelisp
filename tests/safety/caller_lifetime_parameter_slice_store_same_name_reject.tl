;; A lifetime the signature names only in a slice element is the caller's too:
;; a borrow of the same-named parameter cannot be stored into the slice.
(define (store [a : i64] [items : (&mut r (Slice (& a i64)))]) : unit
  ; Must fail: `(& a)` borrows the parameter.
  (set! (array-ref items 0) (& a)))

(define (main) : i64
  0)