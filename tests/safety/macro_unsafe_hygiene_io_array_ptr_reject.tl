(import stdlib.io)

(define (main) : i64
  (let
    [buf : (__tl_dyn-array u8) (__tl_make-array u8 4)]
    [p : (MutPtr (__tl_dyn-array u8))
      (unsafe
        (ptr-addr-of buf))]
    [raw : (MutPtr u8) (io.array-ptr (ptr-read p))]
    (if (ptr-null? raw)
      0
      1)))