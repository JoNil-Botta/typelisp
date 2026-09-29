;; Moving a shadowing binding does not move the outer local of the same name.
(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (sum [t : Token] [other : Token]) : i64
  (let
    [first : i64
      (let
        [t : Token other]
        (consume t))]
    (+ first (consume t))))

(define (main) : i64
  (sum (Token 40 "t") (Token 2 "other")))