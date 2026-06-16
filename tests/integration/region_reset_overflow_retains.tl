(extern (tl_alloc [arg0 : u64]) : u64)
(extern (tl_region_mark) : u64)
(extern (tl_region_reset [arg0 : u64]) : unit)
(extern (tl_arena_poison_enable) : unit)

(define (write-u64! [addr : u64] [value : u64]) : unit
  (unsafe
    (ptr-write! (int->ptr addr : (MutPtr u64)) value)))

(define (read-u64 [addr : u64]) : u64
  (unsafe
    (ptr-read (int->ptr addr : (Ptr u64)))))

(define (main) : i64
  (begin
    (tl_arena_poison_enable)
    (let
      [seed : u64 (tl_alloc (cast 16 : u64))]
      [mark : u64 (tl_region_mark)]
      [first : u64 (tl_alloc (cast 67108864 : u64))]
      (begin
        (write-u64! seed (cast 7 : u64))
        (write-u64! first (cast 111 : u64))
        (tl_region_reset mark)
        (let
          [second : u64 (tl_alloc (cast 67108864 : u64))]
          (begin
            (write-u64! second (cast 222 : u64))
            (let
              [stale : u64 (read-u64 first)]
              (if (and (not (= first second)) (not (= stale (cast 222 : u64))))
                42
                1))))))))