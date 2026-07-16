(module spmd_fixture)

(define (helper [x : i64] [scale : i64])
  (:spmd-callable (specialization
    (lanes 8)
    (args varying uniform)
    (result varying)
    (index-param 0))) : i64
  (+ x scale))