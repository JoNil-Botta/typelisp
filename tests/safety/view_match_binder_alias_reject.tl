;; Two matches on one view bind the same part: while one binding is still
;; written, the other cannot keep a view of the string it frees (a use after
;; free; Rust E0499).
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

(define (f [p : (&mut p Out)]) : i64
  (let
    [v p.e]
    (match v
      [(Shape.Filled y)
        (match v
          [(Shape.Filled z)
            (let
              [s (deref z.b)]
              [_old (replace! (deref y.b) "new")]
              (string.string-length (& s)))]
          [(Shape.Empty _) 0])]
      [(Shape.Empty _) 0])))

(define (main) : i64
  42)