;: SPEC byte view contract: byte views cannot escape their owner's arena.
(import stdlib.byte_buf)

(define (bad [seed : (& outer bytes)]) : (& outer bytes)
  (begin
    (byte_buf.bytes-length seed)
    (with-arena
      phase
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-string "x")]
        (byte_buf.as-bytes (& phase buf))))))

(define (main) : i64
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "seed")]
    [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
    (byte_buf.bytes-length (bad view))))