;; The manifest supplies the same boundary table to both native hosts.
(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.string)

(define (main) : i64
  (let
    [kind : String
      (byte_buf.to-string (io.stdin-read-buffer (io.stdin-read-line)))]
    [capacity : i64
      (if (string.contains (& kind) "empty")
        0
        4)]
    [count : i64
      (cond
        [(string.contains (& kind) "negative") -1]
        [(string.contains (& kind) "maximum") 9223372036854775807]
        [(string.contains (& kind) "over") (+ capacity 1)]
        [(string.contains (& kind) "equal") capacity]
        [else 0])]
    [buf : byte_buf.ByteBuf
      (byte_buf.ByteBuf (__tl_make-array u8 capacity) count)]
    (cond
      [(string.is-string-prefix-at (& kind) "append" 0)
        (let
          [src : String
            (if (string.contains (& kind) "zero")
              ""
              "x")]
          [view : (& src bytes) (byte_buf.str-as-bytes (& src))]
          [out : byte_buf.ByteBuf (byte_buf.append-bytes buf view)]
          (if (= (byte_buf.len (& out)) (+ count (byte_buf.bytes-length view)))
            42
            1))]
      [(string.is-string-prefix-at (& kind) "mutable" 0)
        (let
          [view : (&mut buf bytes) (byte_buf.as-mut-bytes (&mut buf))]
          (if (= (byte_buf.bytes-mut-length view) count)
            (if (> count 0)
              (begin
                (byte_buf.bytes-set! view (- count 1) (cast 73 : u8))
                (if (= (byte_buf.bytes-mut-ref view (- count 1)) (cast 73 : u8))
                  42
                  1))
              42)
            1))]
      [else
        (let
          [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
          (if (= (byte_buf.bytes-length view) count)
            42
            1))])))