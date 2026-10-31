(import stdlib.compress.deflate)
(import stdlib.byte_buf)
(import stdlib.io)

;; Stored LEN=5, complemented LEN, payload and a following container suffix.
(define (example-input) : byte_buf.ByteBuf
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    (set! buf (byte_buf.push buf (cast 1 : u8)))
    (set! buf (byte_buf.push buf (cast 5 : u8)))
    (set! buf (byte_buf.push buf (cast 0 : u8)))
    (set! buf (byte_buf.push buf (cast 250 : u8)))
    (set! buf (byte_buf.push buf (cast 255 : u8)))
    (byte_buf.append-string buf "helloTAIL")))

;; `main` prints and returns 42 when the member decodes to "hello" and
;; consumption stops before the four-byte `TAIL` suffix.
(define (main) : i64
  (let
    [member : byte_buf.ByteBuf (example-input)]
    [limits : deflate.DeflateLimits (deflate.default-limits)]
    [result : i64
      (match (deflate.decode (byte_buf.as-bytes (& member)) (& limits))
        [(deflate.DeflateDecodeErr _) 1]
        [(deflate.DeflateDecodeOk decoded)
          (if (and
            (= decoded.consumed 10)
            (= (byte_buf.len decoded.bytes) 5)
            (= (byte_buf.get decoded.bytes 0 (cast 0 : u8)) (cast 104 : u8))
            (= (byte_buf.get decoded.bytes 4 (cast 0 : u8)) (cast 111 : u8)))
            42
            1)])]
    (io.print-format "{}" "deflate decode score: ")
    (io.println "{}" result)
    result))