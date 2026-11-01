;; Another view of the matched path cannot be taken while a binding of the
;; match is still written (Rust E0499).
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

(define (f [p : (&mut p Out)]) : unit
  (let
    [v p.e]
    (match v
      [(Shape.Filled x)
        (set! x.n 3)
        (let
          [_w p.e]
          (set! x.n 4))]
      [(Shape.Empty _) unit])))

(define (main) : i64
  42)