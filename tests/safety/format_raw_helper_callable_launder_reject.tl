(import stdlib.byte_buf)

(define (main) : i64
  (let
    [_raw : (-> i64 String i64)
      (unsafe
        byte_buf.format-write-raw)]
    0))