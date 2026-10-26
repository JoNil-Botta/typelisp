;; A mutable view's box contents are the referent's: the store lands in
;; the caller's struct (main 4e46ce356 exits 2).
(import stdlib.string)

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
    [v p.s]
    (set! (deref v.b) "zz")))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (string.string-length (& (deref o.s.b)))))