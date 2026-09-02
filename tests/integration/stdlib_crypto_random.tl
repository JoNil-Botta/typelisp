(import stdlib.byte_buf)
(import stdlib.crypto_random)

(define (fill-ok? [buf : (&mut buf byte_buf.ByteBuf)]) : bool
  (match (crypto_random.fill-random! (byte_buf.as-mut-bytes buf))
    [(crypto_random.OkFillRandom) true]
    [(crypto_random.ErrFillRandom _) false]))

(define (main) : i64
  (let
    [first : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 32))]
    [second : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 32))]
    (cond
      [(not (fill-ok? (&mut first))) 1]
      [(not (fill-ok? (&mut second))) 2]
      [(!= (byte_buf.len first) 32) 3]
      [(!= (byte_buf.len second) 32) 4]
      [else 42])))