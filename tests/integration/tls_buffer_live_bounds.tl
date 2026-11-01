(import stdlib.byte_buf)
(import stdlib.net.tls_wire)

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.ByteBuf (__tl_make-array u8 4) -1)]
    (begin
      (tls_wire.buffer-append! (&mut buf) (byte_buf.str-as-bytes "x") 0 1)
      1)))