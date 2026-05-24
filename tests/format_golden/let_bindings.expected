(define (one) : i64
  (let
    [x : i64 1]
    x))

(define (multi) : i64
  (let
    [flat : String
      (format-core-render-source-width "(foo [bar 1] baz)\n; leading\n(qux)" 80)]
    [narrow : String (format-core-render-source-width "(alpha beta gamma)" 10)]
    [atom : String (format-core-render (FmtCstAtom (FmtSymbol "name")))]
    0))

(define (long) : i64
  (let
    [value : i64
      (add-very-long-name alpha beta gamma delta epsilon zeta eta theta)]
    value))

(define (unannotated) : i64
  (let
    [x 1]
    [y (+ x 1)]
    y))

(define (commented) : i64
  (let
    ; keep first binding
    [x : i64 1]
    ; keep second binding
    [y : i64 2]
    (+ x y)))

(define (nested) : i64
  (let
    [x : i64 1]
    [y : i64 2]
    (let
      [z : i64 (+ x y)]
      z)))