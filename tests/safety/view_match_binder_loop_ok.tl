;; A mutable view's match repeated in a loop writes the caller's struct each
;; time (main 4e46ce356 exits 6).
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
    [i 0]
    (while (< i 2)
      (match p.e
        [(Shape.Filled x) (set! x.n (+ x.n 2))]
        [(Shape.Empty _) unit])
      (set! i (+ i 1)))))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (score (& o))))