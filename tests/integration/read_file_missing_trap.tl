(import stdlib.io)
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [bytes : byte_buf.ByteBuf
      (io.read-file "tests/integration/this-path-does-not-exist-zzz.txt")]
    (byte_buf.len (& bytes))))