(extern (tl_alloc [arg0 : i64]) : u64)

(define (main) : i64
  (begin
    (tl_alloc 16)
    0))