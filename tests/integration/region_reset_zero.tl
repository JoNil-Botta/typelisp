(import "stdlib/string.tl")

(extern (tl_region_mark) : u64)

(extern (tl_region_reset [arg0 : u64]) : unit)

(define (main) : i64
  (begin
    (string-append "left" "right")
    (tl_region_reset (cast 0 : u64))
    (if (= (tl_region_mark) (cast 0 : u64))
      44
      1)))