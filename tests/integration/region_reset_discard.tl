(import "stdlib/string.tl")

(extern (tl_alloc [arg0 : u64]) : u64)

(extern (tl_region_mark) : u64)

(extern (tl_region_reset [arg0 : u64]) : unit)

(define (main) : i64
  (let
    [before : String (string-append "a" "b")]
    [m : u64 (tl_region_mark)]
    (begin
      (tl_alloc (cast 67108864 : u64))
      (tl_region_reset m)
      (string-length (string-append before "c")))))