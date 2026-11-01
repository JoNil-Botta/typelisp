;; Joining a borrow of a value read through a caller reference with a borrow of
;; a same-spelled local keeps the loan on the first, keyed by the caller's
;; lifetime, while the array lives.
(defstruct Span
  (bounds (Tuple i64 i64)))

; Must fail: `y` is assigned while `rs` borrows it.
(define (f [p : (& a Span)]) : i64
  (let
    [y p.bounds]
    [a : (Tuple i64 i64) (tuple 2 2)]
    [rs (array (& a) (& y))]
    (set! y (tuple 10 10))
    (tuple-ref (deref (array-ref rs 1)) 0)))

(define (main) : i64
  0)