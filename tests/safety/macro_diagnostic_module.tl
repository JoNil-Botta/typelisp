(defmacro (gen) : Module
  `(define (answer) : i64
    42))

(import (gen))

(define (main) : i64
  0)