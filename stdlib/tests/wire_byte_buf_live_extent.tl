(import stdlib.byte_buf)
(import stdlib.io)
(import stdlib.net.tls_wire as tls)
(import stdlib.ssh_wire_core as ssh)
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
    [source : String
      (if (string.contains (& kind) "one")
        "x"
        "")]
    [bytes : (& source bytes) (byte_buf.str-as-bytes (& source))]
    [n : i64 (byte_buf.bytes-length bytes)]
    [i : i64 0]
    (while (< i capacity)
      (set! (array-ref buf.slots i) (cast (+ 65 i) : u8))
      (set! i (+ i 1)))
    (if (string.is-string-prefix-at (& kind) "tls" 0)
      (tls.buffer-append! (&mut buf) bytes 0 n)
      (ssh.buffer-append! (&mut buf) bytes 0 n))
    (let
      [prefix-ok : bool true]
      [index : i64 0]
      (while (< index count)
        (when
          (!= (array-ref buf.slots index) (cast (+ 65 index) : u8))
          (set! prefix-ok false))
        (set! index (+ index 1)))
      (if (and
        prefix-ok
        (= buf.len (+ count n))
        (if (= n 1)
          (= (array-ref buf.slots count) (cast 120 : u8))
          true))
        42
        1))))