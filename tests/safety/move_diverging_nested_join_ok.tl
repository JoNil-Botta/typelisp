(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (pick [a : bool] [b : bool]) : i64
  (let
    [t : Token (Token 40 "t")]
    [u : Token (Token 2 "u")]
    (begin
      (if a
        (begin
          (if b
            (return (consume t))
            unit)
          (return (+ (consume t) (consume u))))
        unit)
      (+ (consume t) (consume u)))))

(define (main) : i64
  (if (and (= (pick true true) 40) (= (pick true false) 42))
    (pick false false)
    1))