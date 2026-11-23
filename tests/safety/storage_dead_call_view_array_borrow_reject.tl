;; #9288: a call-returned region-tagged fixed array is stored in the caller's
;; frame, not as a view alias, so returning `(& xs)` must fail E0205.
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defstruct Out
  (xs (Array In 2))
  (t i64))

(define (get-xs [x : (& p Out)]) : (in p (Array In 2))
  x.xs)

(define (leak [p : (& p Out)]) : (& p (Array In 2))
  (let
    [xs (get-xs p)]
    (& xs)))

(define (main) : i64
  (let
    [o : Out (Out (array (In (box 42) 1 2) (In (box 7) 3 4)) 0)]
    [r (leak (& o))]
    (array-length r)))