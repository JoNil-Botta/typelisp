(extern tl_alloc : (-> i64 u64))

(define (main) : i64
  (begin
    (tl_alloc 16)
    0))