;; A `let` that shadows a moved local leaves it moved after the `let` ends.
(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (twice [t : Token]) : i64
  (let
    [first : i64 (consume t)]
    (begin
      (let
        [t : i64 1]
        t)
      (+ first (consume t)))))

(define (main) : i64
  (twice (Token 41 "t")))