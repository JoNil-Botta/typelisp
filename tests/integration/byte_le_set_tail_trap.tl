;: An invalid eight-byte field aborts before the raw set.
(import stdlib.byte_le)

(define (main) : i64
  (let
    [bytes : (__tl_dyn-array u8) (__tl_make-array u8 8)]
    (byte_le.set-u64! (&mut bytes) 1 42)
    0))