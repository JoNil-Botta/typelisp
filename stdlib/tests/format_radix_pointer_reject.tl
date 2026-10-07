(import stdlib.format)

(define (main) : i64
  (unsafe
    (let
      [value : (Ptr u8) (int->ptr (cast 1 : u64) : (Ptr u8))]
      (format.format "{:x}" value)
      42)))