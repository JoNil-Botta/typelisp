;; A mutable view lends its referent mutably (main 4e46ce356 exits 2).
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

(define (bump-in [q : (&mut q In)]) : unit
  (set! q.n (+ q.n 1)))

(define (f [p : (&mut p Out)]) : unit
  (let
    [v p.s]
    (bump-in (&mut v))))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    o.s.n))