(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

;; The `return` belongs to the lambda, not to the arm: the arm completes
;; normally, so its move still reaches the join.
(define (pick [flag : bool]) : i64
  (let
    [t : Token (Token 41 "t")]
    (begin
      (if flag
        (begin
          (consume t)
          (let
            [f : (-> i64)
              (lambda () : i64
                (return 7))]
            (f))
          unit)
        unit)
      (+ (consume t) 1))))

(define (main) : i64
  (pick false))