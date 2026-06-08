(extern (tl_region_mark) : u64)

(define (main) : i64
  (if (= (tl_region_mark) (cast 0 : u64))
    42
    1))