;; A match on a mutable view binder matches a fresh view of its referent: its
;; bindings are mutable views too (main 4e46ce356 exits 8).
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
  (let
    [v p.e]
    (match v
      [(Shape.Filled x) (set! x.n (+ x.n 6))]
      [(Shape.Empty _) unit])))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (score (& o))))