;: SPEC byte view contract: out-of-range byte view reads trap.
(import "stdlib/byte_buf.tl")

(define (main) : i64
  (let
    [buf : ByteBuf (byte-buf-from-string "ab")]
    [view : (& buf bytes) (byte-buf-as-bytes (& buf))]
    (cast (bytes-ref view 2) : i64)))