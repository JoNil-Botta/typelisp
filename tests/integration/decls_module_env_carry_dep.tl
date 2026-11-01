(import stdlib.hashmap)
(import (hashmap.hashmap i64 i64) as counts)

(define (helper [x : i64]) : i64
  (+ x 1))

(define (fresh-counts) : counts.Map
  (counts.with-capacity 4))

(unsafe
  (define (hidden) : i64
    19))

(defmacro (step [name : Expr] [prev : Expr] [add : Expr]) : Decls
  `(define (,name [x : i64]) : i64
    (,prev (+ x ,add))))

(define (step0 [x : i64]) : i64
  (helper x))

(step step1 step0 1)

(step step2 step1 2)

(step step3 step2 3)

(step step4 step3 4)

(step step5 step4 5)

(step step6 step5 6)

;; A root collision takes the rebuild, then later unique splices carry again.
(step shared-name step6 7)

(step step7 shared-name 8)

(define (last [x : i64]) : i64
  (step7 x))

(define (preserved-unsafe) : i64
  (unsafe
    (hidden)))