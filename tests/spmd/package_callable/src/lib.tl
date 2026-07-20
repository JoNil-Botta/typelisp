(module spmd_fixture)

(define (helper [x : i64] [scale : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param 0)))
  : i64
  (+ x scale))

(define (shifted [x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result varying)
      (index-param none)))
  : i64
  (+ x 5))

(define (positive? [x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result varying)
      (index-param 0)))
  : bool
  (> x 5))

(define (constant [x : i64] [value : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i64
  value)

(define (sink [x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result unit)
      (index-param none)))
  : unit
  unit)

(define (add-f64 [x : f64] [scale : f64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result varying)
      (index-param none)))
  : f64
  (+ x scale))

(define (add-f32 [x : f32] [scale : f32])
  (:spmd-callable
    (specialization
      (lanes 16)
      (args varying uniform)
      (result varying)
      (index-param none)))
  : f32
  (+ x scale))