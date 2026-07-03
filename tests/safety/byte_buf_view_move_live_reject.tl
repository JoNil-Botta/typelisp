;: SPEC byte view contract: an owned buffer cannot move while a view is live.
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "abc")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    [moved : byte_buf.ByteBuf buf]
    (+ (byte_buf.bytes-length view) (byte_buf.len moved))))