;; #9288: a call-returned region-tagged struct is stored in the caller's frame,
;; not as a view alias of a referent, so returning `(& v)` must fail E0205.
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defstruct Out
  (s In)
  (t i64))

(define (get [x : (& p Out)]) : (in p In)
  x.s)

(define (leak [p : (& p Out)]) : (& p In)
  (let
    [v (get p)]
    (& v)))

(define (main) : i64
  (let
    [o : Out (Out (In (box 42) 1 2) 9)]
    [r (leak (& o))]
    (+ r.n r.m)))