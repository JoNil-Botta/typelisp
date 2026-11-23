;; #9288: a call-returned region-tagged tuple is stored in the caller's frame,
;; not as a view alias of a referent, so returning `(& t)` must fail E0205.
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defstruct Out
  (pair (Tuple In i64))
  (t i64))

(define (get-pair [x : (& p Out)]) : (in p (Tuple In i64))
  x.pair)

(define (leak [p : (& p Out)]) : (& p (Tuple In i64))
  (let
    [t (get-pair p)]
    (& t)))

(define (main) : i64
  (let
    [o : Out (Out (tuple (In (box 42) 1 2) 9) 0)]
    [r (leak (& o))]
    (tuple-ref (deref r) 1)))