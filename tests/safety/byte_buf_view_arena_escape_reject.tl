;: SPEC byte view contract: byte views cannot escape their owner's arena.
(import "stdlib/byte_buf.tl")

(define (bad [seed : (& outer bytes)]) : (& outer bytes)
  (begin
    (bytes-length seed)
    (with-arena
      phase
      (let
        [buf : ByteBuf (byte-buf-from-string "x")]
        (byte-buf-as-bytes (& phase buf))))))

(define (main) : i64
  (let
    [buf : ByteBuf (byte-buf-from-string "seed")]
    [view : (& buf bytes) (byte-buf-as-bytes (& buf))]
    (bytes-length (bad view))))