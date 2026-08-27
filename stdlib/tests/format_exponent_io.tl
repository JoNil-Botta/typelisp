(import stdlib.format)
(import stdlib.io)
(import stdlib.math)

(define (main) : i64
  (begin
    (io.println "{:.3e}" (cast 12345 : i32))
    (io.print-error
      (format.format "{:E}" (math.f32-from-bits (cast 0x00000001 : u32))))
    42))