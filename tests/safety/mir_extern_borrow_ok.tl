;: An extern's read of an owner is compatible with a live shared borrow of it.
(extern (items-bits [items : (__tl_dyn-array i64)] [scale : f64]) : u64 (:symbol "tl_float_to_bits"))

(define (pick [items : (__tl_dyn-array i64)]) : i64
  (let
    [view : (& items (__tl_dyn-array i64)) (& items)]
    [bits : u64 (items-bits items 1.0)]
    (+
      (array-length view)
      (if (= bits bits)
        0
        1))))

(define (main) : i64
  0)