;; #9288: borrowing a field of a region-tagged by-value parameter borrows
;; the call-frame parameter copy, not the caller's storage, so returning it
;; must fail E0205.
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defstruct Out
  (s In)
  (t i64))

(define (get [x : (& p Out)]) : (in p In)
  x.s)

(define (leak [_a : (& p Out)] [v : (in p In)]) : (& p i64)
  (& v.n))

(define (main) : i64
  (let
    [o : Out (Out (In (box 42) 1 2) 9)]
    [v (get (& o))]
    [r (leak (& o) v)]
    (deref r)))