;; #9288: binding a call-returned region-tagged enum in `let` and then matching
;; it borrows the local frame copy `e`, so returning `(& x)` must fail E0205.
(defstruct In
  (b (Box i64))
  (n i64)
  (m i64))

(defenum E
  (A In)
  (B i64))

(defstruct Out
  (e E)
  (s In))

(define (get-e [x : (& p Out)]) : (in p E)
  x.e)

(define (leak [p : (& p Out)]) : (& p In)
  (let
    [e (get-e p)]
    (match e
      [(A x) (& x)]
      [(B _) (& p.s)])))

(define (main) : i64
  (let
    [o : Out (Out (E.A (In (box 42) 1 2)) (In (box 1) 3 4))]
    [r (leak (& o))]
    (+ r.n r.m)))