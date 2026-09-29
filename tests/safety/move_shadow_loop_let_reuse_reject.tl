;; A shadowing `let` in a loop body leaves the moved local moved after it ends.
(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (count [n : i64]) : i64
  (let
    [total : i64 0]
    (begin
      (while (< total n)
        (let
          [t : Token (Token 1 "t")]
          (begin
            (set! total (+ total (consume t)))
            (let
              [t : i64 1]
              (set! total (+ total t)))
            (set! total (+ total (consume t))))))
      total)))

(define (main) : i64
  (count 3))