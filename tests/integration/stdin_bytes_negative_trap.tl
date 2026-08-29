(import stdlib.io)

;; lint-allow: unused-import
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [bytes : byte_buf.ByteBuf (io.read-stdin-bytes -1)]
    (byte_buf.len (& bytes))))