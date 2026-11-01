;; A view read through a mutable view is mutable too: every reference on its
;; path is `&mut` (main 4e46ce356 exits 9).
(defstruct In
  (b (Box String))
  (n i64))

(defstruct Mid
  (i In)
  (k i64))

(defstruct Out
  (s In)
  (m Mid)
  (t i64))

(define (make-out) : Out
  (Out (In (box "a") 1) (Mid (In (box "c") 3) 4) 5))

(define (f [p : (&mut p Out)]) : unit
  (let
    [v p.m]
    [u v.i]
    (set! u.n (+ u.n 6))))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    o.m.i.n))