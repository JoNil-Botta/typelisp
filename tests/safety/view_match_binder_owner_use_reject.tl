;; A written match binding holds an exclusive loan of the matched path while it
;; is used: the owner cannot be read in between (Rust E0502).
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

(define (look [p : (& p Out)]) : i64
  p.t)

(define (f [p : (&mut p Out)]) : unit
  (match p.e
    [(Shape.Filled x)
      (let
        [t (look p)]
        (set! x.n t))]
    [(Shape.Empty _) unit]))

(define (main) : i64
  42)