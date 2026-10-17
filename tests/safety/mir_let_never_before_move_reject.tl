;; An initializer's divergence does not erase a prior live ownership error.
(import stdlib.io)

(define (consume [items : (__tl_dyn-array i64)]) : i64
  (array-length items))

(define (invalid [items : (__tl_dyn-array i64)]) : i64
  (let
    [spent : i64 (consume items)]
    [answer : i64
      (begin
        (consume items)
        (io.panic "too late"))]
    (+ spent answer)))

(define (main) : i64
  (invalid (__tl_make-array i64 1)))