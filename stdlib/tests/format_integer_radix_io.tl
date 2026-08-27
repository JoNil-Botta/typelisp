(import stdlib.format)
(import stdlib.io)

(define (main) : i64
  (let
    [lower-owner : u8 (cast 42 : u8)]
    [lower : (& lower-owner u8) (& lower-owner)]
    [upper-owner : u8 (cast 255 : u8)]
    [upper : (& upper-owner u8) (& upper-owner)]
    (begin
      (io.print-format "{:#x}/" lower)
      (io.println "{:08b}" (cast 5 : u8))
      (io.print-error (format.format "{:#X}" upper))
      42)))