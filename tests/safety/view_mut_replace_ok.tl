;; A view read through `&mut` references only is a mutable view of the
;; referent's storage: replace! of its field writes the caller's struct
;; (main 4e46ce356 exits 2).
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
    [_old (replace! v.b (box "zz"))]
    unit))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (string.string-length (& (deref o.s.b)))))