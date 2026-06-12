;; Repr-c f32 fields use 4-byte scalar storage and can be constructed and read.
(import "stdlib/core_macros.tl" module stdlib.core_macros as core)

(defstruct ReprCF32
  (:repr c)
  (x f32)
  (y f32)
  (tag i64))

(define (main) : i64
  (let
    [value : ReprCF32 (ReprCF32 1.5 2.25 40)]
    [x : f32 (struct-get value x)]
    [y : f32 (struct-get value y)]
    [want-x : f32 1.5]
    [want-y : f32 2.25]
    (core/cond
      (< x want-x)
      1
      (> x want-x)
      2
      (< y want-y)
      3
      (> y want-y)
      4
      (+ (struct-get value tag) 2))))