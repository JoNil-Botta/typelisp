;; Box contents reached through a mutable view's binding are the referent's:
;; replace! takes the old string out and the store lands (main 4e46ce356
;; exits 4).
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
      [(Shape.Filled x)
        (let
          [old (replace! (deref x.b) "zzz")]
          (set! x.n (string.string-length (& old))))]
      [(Shape.Empty _) unit])))

(define (main) : i64
  (let
    [o : Out (make-out)]
    (f (&mut o))
    (score (& o))))