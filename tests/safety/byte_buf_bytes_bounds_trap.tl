;: SPEC byte view contract: out-of-range byte view reads trap.
(import stdlib.byte_buf)

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "ab")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    (cast (byte_buf.bytes-ref view 2) : i64)))