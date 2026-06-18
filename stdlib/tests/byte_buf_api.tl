(import "stdlib/byte_buf.tl")
(import "stdlib/test.tl")

(define (assert-u8-eq [actual : u8] [expected : i64] [message : String]) : unit
  (assert-i64-eq (cast actual : i64) expected message))

(define (make-u8 [value : i64]) : u8
  (cast value : u8))

(define (main) : i64
  (let
    [src : (Array u8) (make-array u8 4)]
    (begin
      (array-set! src 0 (make-u8 65))
      (array-set! src 1 (make-u8 0))
      (array-set! src 2 (make-u8 128))
      (array-set! src 3 (make-u8 255))
      (let
        [buf : ByteBuf
          (byte-buf-append-string
            (byte-buf-append-array (byte-buf-with-capacity 1) src)
            "ok")]
        (begin
          (assert-i64-eq (byte-buf-len buf) 6 "append len")
          (assert-true (>= (byte-buf-capacity buf) 6) "append capacity")
          (assert-u8-eq (byte-buf-ref buf 0) 65 "first byte")
          (assert-u8-eq (byte-buf-ref buf 1) 0 "nul byte")
          (assert-u8-eq (byte-buf-ref buf 2) 128 "high byte")
          (assert-u8-eq (byte-buf-ref buf 3) 255 "max byte")
          (assert-u8-eq (byte-buf-ref buf 4) 111 "string o")
          (assert-u8-eq (byte-buf-ref buf 5) 107 "string k")
          (let
            [snap : (Array u8) (byte-buf-to-array buf)]
            (begin
              (assert-i64-eq (array-length snap) 6 "snapshot len")
              (array-set! snap 0 (make-u8 1))
              (assert-u8-eq (byte-buf-ref buf 0) 65 "snapshot copies")))
          (let
            [text-buf : ByteBuf (byte-buf-from-string "text")]
            [text : String (byte-buf-to-string text-buf)]
            [expected : String "text"]
            (begin
              (assert-string-eq (& text) (& expected) "string round trip")
              (assert-true
                (byte-buf-empty? (byte-buf-clear! text-buf))
                "clear empties buffer")))
          42)))))