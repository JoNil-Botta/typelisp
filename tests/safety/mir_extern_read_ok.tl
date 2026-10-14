;: A foreign declaration carries no ownership effect: an extern reads its
;: arguments, so an owner passed to it stays usable.
(extern (items-bits [items : (__tl_dyn-array i64)] [scale : f64]) : u64 (:symbol "tl_float_to_bits"))

(define (twice [items : (__tl_dyn-array i64)]) : i64
  (let
    [first : u64 (items-bits items 1.0)]
    [second : u64 (items-bits items 2.0)]
    (if (= first second)
      (array-length items)
      (+ (array-length items) 40))))

(define (main) : i64
  0)