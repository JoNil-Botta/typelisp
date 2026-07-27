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

(define (constant [_x : i64] [value : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i64
  value)

(define (constant-i16 [_x : i16] [value : i16])
  (:spmd-callable
    (specialization
      (lanes 32)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i16
  value)

(define (constant-u16 [_x : u16] [value : u16])
  (:spmd-callable
    (specialization
      (lanes 32)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : u16
  value)

(define (constant-i8 [_x : i8] [value : i8])
  (:spmd-callable
    (specialization
      (lanes 64)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : i8
  value)

(define (constant-u8 [_x : u8] [value : u8])
  (:spmd-callable
    (specialization
      (lanes 64)
      (args varying uniform)
      (result uniform)
      (index-param none)))
  : u8
  value)

(define (literal-constant [_x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result uniform)
      (index-param none)))
  : i64
  7)

(define (cast-constant [_x : i64])
  (:spmd-callable
    (specialization
      (lanes 8)
      (args varying)
      (result uniform)
      (index-param none)))
  : i64
  (cast 11 : i64))

(define (sink [_x : i64])
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