;; A mutable view binding may be borrowed `&mut` for a call, which writes the
;; caller's struct (main 4e46ce356 exits 3).
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

(define (bump [q : (&mut q In)]) : unit
  (set! q.n (+ q.n 1)))

(define (f [p : (&mut p Out)]) : unit
  (match p.e
    [(Shape.Filled x) (bump (&mut x))]
    [(Shape.Empty _) unit]))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (score (& o))))