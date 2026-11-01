;; Public ByteBuf fields are untrusted representation, even in safe code.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [mode : i64 (string.>int (io.arg 1))]
    [capacity : i64
      (if (or (= mode 5) (= mode 8) (= mode 9) (= mode 10))
        0
        4)]
    [length : i64
      (cond
        [(or (= mode 2) (= mode 6)) 5]
        [(or (= mode 3) (= mode 12) (= mode 13)) 9223372036854775807]
        [(or (= mode 4) (= mode 7) (= mode 11)) -1]
        [(or (= mode 5) (= mode 8)) 1]
        [(or (= mode 9) (= mode 10)) 0]
        [else 4])]
    [buf : byte_buf.ByteBuf
      (byte_buf.ByteBuf (__tl_make-array u8 capacity) length)]
    (cond
      [(or (= mode 11) (= mode 12))
        (let
          [next : byte_buf.ByteBuf
            (byte_buf.append-bytes buf (byte_buf.str-as-bytes "x"))]
          (if (= (byte_buf.len next) 5)
            42
            1))]
      [(or (= mode 1) (= mode 6) (= mode 7) (= mode 8) (= mode 10) (= mode 13))
        (if (=
          (byte_buf.bytes-mut-length (byte_buf.as-mut-bytes (&mut buf)))
          length)
          42
          1)]
      [else
        (if (= (byte_buf.bytes-length (byte_buf.as-bytes (& buf))) length)
          42
          1)])))