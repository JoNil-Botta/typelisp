;; A `with` binding that shadows a moved local leaves it moved after the scope.
(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (close [_t : i64]) : unit
  unit)

(define (twice [t : Token]) : i64
  (let
    [first : i64 (consume t)]
    (begin
      (with ([t 1 close]) 0)
      (+ first (consume t)))))

(define (main) : i64
  (twice (Token 41 "t")))