(extern (tl_region_reset [arg0 : u64]) : unit)

(define (main) : i64
  (begin
    (tl_region_reset (cast 1234 : u64))
    0))