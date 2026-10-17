;; One diverging arm does not make the initializer's normal arm unreachable.
(define (consume [items : (__tl_dyn-array i64)]) : i64
  (array-length items))

(define (invalid [items : (__tl_dyn-array i64)] [flag : bool]) : i64
  (let
    [answer : i64
      (if flag
        (return 42)
        (consume items))]
    (+ answer (consume items))))

(define (main) : i64
  (invalid (__tl_make-array i64 1) false))