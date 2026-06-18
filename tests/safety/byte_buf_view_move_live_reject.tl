;: SPEC byte view contract: an owned buffer cannot move while a view is live.
(import "stdlib/byte_buf.tl")

(define (main) : i64
  (let
    [buf : ByteBuf (byte-buf-from-string "abc")]
    [view : (& buf bytes) (byte-buf-as-bytes (& buf))]
    [moved : ByteBuf buf]
    (+ (bytes-length view) (byte-buf-len moved))))