(extern (tl_alloc_aligned [size : i64] [alignment : i64]) : i64)

(define (main) : i64
  (tl_alloc_aligned 9223372036854775807 4096))