;; #9288: reassigning a view-alias binder replaces it with a frame copy, so
;; returning a field borrow through it must fail E0205.
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defstruct Out
  (s In)
  (t i64))

(define (get [x : (& p Out)]) : (in p In)
  x.s)

(define (leak [p : (& p Out)]) : (& p i64)
  (let
    [v p.s]
    (set! v (get p))
    (& v.n)))

(define (main) : i64
  (let
    [o : Out (Out (In (box 42) 1 2) 9)]
    [r (leak (& o))]
    (deref r)))