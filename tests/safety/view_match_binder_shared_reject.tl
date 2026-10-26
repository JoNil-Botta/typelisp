;; A binding of a match on a view read through a shared reference stays shared:
;; a store through it writes through that `&` (Rust E0594). Main 4e46ce356
;; accepts it and writes the caller's struct.
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

(define (f [p : (& p Out)]) : unit
  (match p.e
    [(Shape.Filled x) (set! x.n (+ x.n 6))]
    [(Shape.Empty _) unit]))

(define (main) : i64
  42)