;; The operands before a diverging one still run: a value moved by an earlier
;; argument cannot be used again on the way to the exit.
(import stdlib.io)

(defstruct Token
  (id i64)
  (name String))

(define (consume [t : Token]) : i64
  t.id)

(define (take2 [a : i64] [b : i64]) : i64
  (+ a b))

(define (spend [t : Token]) : i64
  (take2 (consume t) (take2 (consume t) (io.panic "unreachable"))))

(define (main) : i64
  (spend (Token 42 "t")))