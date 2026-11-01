;; replace! of a mutable view binding's field writes the caller's struct
;; (main 4e46ce356 exits 21).
(import stdlib.string)

(defstruct In
  (b (Box String))
  (n i64))

(defenum Shape
  (Filled In)
  (Empty i64))

(defstruct Out
  (e Shape)
  (t i64))

(define (make-out) : Out
  (Out (Shape.Filled (In (box "a") 1)) 5))

(define (score [o : (& o Out)]) : i64
  (match o.e
    [(Shape.Filled x) (+ x.n (string.string-length (& (deref x.b))))]
    [(Shape.Empty k) k]))

(define (f [p : (&mut p Out)]) : unit
  (match p.e
    [(Shape.Filled x)
      (let
        [_old (replace! x.n 20)]
        unit)]
    [(Shape.Empty _) unit]))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (score (& o))))