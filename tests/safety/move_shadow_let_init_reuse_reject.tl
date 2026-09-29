;; A shadowing `let` whose initializer moves the outer local leaves it moved,
;; also when the name is bound twice in the same `let`.
(defstruct Token
  (id i64)
  (name String))

(define (pass [t : Token]) : Token
  t)

(define (consume [t : Token]) : i64
  t.id)

(define (twice [t : Token]) : i64
  (let
    [first : i64
      (let
        [t : Token (pass t)]
        [t : Token (pass t)]
        (consume t))]
    (+ first (consume t))))

(define (main) : i64
  (twice (Token 41 "t")))