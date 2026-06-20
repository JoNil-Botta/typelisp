;; Decimal float literals whose contextual f32 rounding is non-finite are rejected.
(define too-big : f32
  340282400000000000000000000000000000000.0)

(define (main) : i64
  0)