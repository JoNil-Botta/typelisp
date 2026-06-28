(import stdlib.array)
(import stdlib.byte_buf)
(import stdlib.test)

(define (assert-u8-eq [actual : u8] [expected : i64] [message : String]) : unit
  (test.assert-i64-eq (cast actual : i64) expected message))

(define (make-u8 [value : i64]) : u8
  (cast value : u8))

(define (string-byte [text : String] [index : i64]) : u8
  (unsafe
    (ptr-read (ptr-offset (string-data (& text)) index))))

(define (assert-basic-growth) : unit
  (begin
    (let
      [empty : byte_buf.ByteBuf (byte_buf.byte-buf-with-capacity 2)]
      (begin
        (test.assert-i64-eq (byte_buf.byte-buf-len empty) 0 "empty len")
        (test.assert-i64-eq
          (byte_buf.byte-buf-length empty)
          0
          "empty length alias")
        (test.assert-i64-eq
          (byte_buf.byte-buf-capacity empty)
          2
          "empty capacity")
        (test.assert-true (byte_buf.byte-buf-empty? empty) "empty predicate")
        (assert-u8-eq
          (byte_buf.byte-buf-get empty 0 (make-u8 77))
          77
          "empty get fallback")))
    (test.assert-i64-eq
      (byte_buf.byte-buf-capacity (byte_buf.byte-buf-with-capacity 0))
      1
      "zero capacity clamps")
    (let
      [buf : byte_buf.ByteBuf (byte_buf.byte-buf-with-capacity 2)]
      (begin
        (set! buf (byte_buf.byte-buf-push buf (make-u8 10)))
        (set! buf (byte_buf.byte-buf-push buf (make-u8 20)))
        (test.assert-i64-eq (byte_buf.byte-buf-len buf) 2 "push len")
        (test.assert-i64-eq (byte_buf.byte-buf-capacity buf) 2 "push no growth")
        (assert-u8-eq (byte_buf.byte-buf-ref buf 0) 10 "ref first")
        (assert-u8-eq (byte_buf.byte-buf-ref buf 1) 20 "ref second")
        (set! buf (byte_buf.byte-buf-push buf (make-u8 30)))
        (test.assert-i64-eq (byte_buf.byte-buf-len buf) 3 "growth push len")
        (test.assert-i64-eq
          (byte_buf.byte-buf-capacity buf)
          4
          "growth capacity")
        (assert-u8-eq (byte_buf.byte-buf-ref buf 2) 30 "growth value")
        (set! buf (byte_buf.byte-buf-set! buf 1 (make-u8 99)))
        (assert-u8-eq (byte_buf.byte-buf-ref buf 1) 99 "set value")
        (set! buf (byte_buf.byte-buf-reserve buf 5))
        (test.assert-i64-eq (byte_buf.byte-buf-len buf) 3 "reserve keeps len")
        (test.assert-true
          (>= (byte_buf.byte-buf-capacity buf) 8)
          "reserve grows enough")
        (set! buf (byte_buf.byte-buf-clear! buf))
        (test.assert-true (byte_buf.byte-buf-empty? buf) "clear empties")
        (set! buf (byte_buf.byte-buf-push buf (make-u8 7)))
        (test.assert-i64-eq (byte_buf.byte-buf-len buf) 1 "reuse after clear")
        (assert-u8-eq (byte_buf.byte-buf-ref buf 0) 7 "reuse value")))))

(define (assert-array-copy) : unit
  (let
    [src : (Array u8) (array.make-array u8 4)]
    (begin
      (array.array-set! src 0 (make-u8 1))
      (array.array-set! src 1 (make-u8 0))
      (array.array-set! src 2 (make-u8 200))
      (array.array-set! src 3 (make-u8 255))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.byte-buf-from-array src)]
        (begin
          (test.assert-i64-eq (byte_buf.byte-buf-len buf) 4 "from-array len")
          (array.array-set! src 2 (make-u8 2))
          (assert-u8-eq (byte_buf.byte-buf-ref buf 2) 200 "from-array copies")
          (let
            [slice : (Array u8) (byte_buf.byte-buf-copy-range buf 1 2)]
            (begin
              (test.assert-i64-eq (array.array-length slice) 2 "copy-range len")
              (assert-u8-eq (array.array-ref slice 0) 0 "copy-range first")
              (assert-u8-eq (array.array-ref slice 1) 200 "copy-range second")))
          (let
            [snap : (Array u8) (byte_buf.byte-buf-to-array buf)]
            (begin
              (test.assert-i64-eq (array.array-length snap) 4 "to-array len")
              (assert-u8-eq (array.array-ref snap 3) 255 "to-array last")
              (array.array-set! snap 3 (make-u8 3))
              (assert-u8-eq (byte_buf.byte-buf-ref buf 3) 255 "to-array copies"))))))))

(define (assert-mixed-append) : unit
  (let
    [src : (Array u8) (array.make-array u8 3)]
    (begin
      (array.array-set! src 0 (make-u8 65))
      (array.array-set! src 1 (make-u8 66))
      (array.array-set! src 2 (make-u8 67))
      (let
        [buf : byte_buf.ByteBuf
          (byte_buf.byte-buf-append-array-range
            (byte_buf.byte-buf-append-string (byte_buf.byte-buf-new) "xy")
            src
            1
            2)]
        (begin
          (let
            [actual : String (byte_buf.byte-buf-to-string buf)]
            [expected : String "xyBC"]
            (test.assert-string-eq
              (& actual)
              (& expected)
              "append string and array range"))
          (test.assert-i64-eq (byte_buf.byte-buf-len buf) 4 "append mixed len"))))))

(define (assert-string-roundtrip) : unit
  (let
    [buf : byte_buf.ByteBuf (byte_buf.byte-buf-from-string "hello")]
    (begin
      (test.assert-i64-eq (byte_buf.byte-buf-len buf) 5 "from-string len")
      (assert-u8-eq (byte_buf.byte-buf-ref buf 1) 101 "from-string e")
      (let
        [out : String (byte_buf.byte-buf-to-string buf)]
        [expected : String "hello"]
        (test.assert-string-eq (& out) (& expected) "to-string text")))))

(define (assert-borrowed-bytes) : unit
  (let
    [text : String "abcdef"]
    [view : (& text bytes) (byte_buf.str-as-bytes (& text))]
    [middle : (& text bytes) (byte_buf.bytes-slice-view view 2 3)]
    (begin
      (test.assert-i64-eq (byte_buf.bytes-length view) 6 "bytes view len")
      (assert-u8-eq (byte_buf.bytes-ref view 1) 98 "bytes ref")
      (assert-u8-eq
        (byte_buf.bytes-get view 99 (make-u8 77))
        77
        "bytes get fallback")
      (test.assert-i64-eq
        (byte_buf.bytes-length middle)
        3
        "bytes sub-slice len")
      (assert-u8-eq (byte_buf.bytes-ref middle 0) 99 "bytes sub-slice first")
      (let
        [arr : (Array u8) (byte_buf.bytes-to-array middle)]
        (begin
          (test.assert-i64-eq (array.array-length arr) 3 "bytes to-array len")
          (assert-u8-eq (array.array-ref arr 2) 101 "bytes to-array last")))
      (let
        [copy : String (byte_buf.bytes-to-string middle)]
        [expected : String "cde"]
        (test.assert-string-eq (& copy) (& expected) "bytes to-string"))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.byte-buf-from-bytes middle)]
        [actual : String (byte_buf.byte-buf-to-string buf)]
        [expected : String "cde"]
        (test.assert-string-eq (& actual) (& expected) "byte-buf from bytes"))
      (let
        [buf : byte_buf.ByteBuf
          (byte_buf.byte-buf-append-bytes
            (byte_buf.byte-buf-from-string "x")
            middle)]
        [actual : String (byte_buf.byte-buf-to-string buf)]
        [expected : String "xcde"]
        (test.assert-string-eq (& actual) (& expected) "byte-buf append bytes")))))

(define (assert-byte-buf-views) : unit
  (begin
    (let
      [buf : byte_buf.ByteBuf (byte_buf.byte-buf-from-string "view")]
      [view : (& buf bytes) (byte_buf.byte-buf-as-bytes (& buf))]
      (begin
        (test.assert-i64-eq (byte_buf.bytes-length view) 4 "byte-buf view len")
        (assert-u8-eq
          (byte_buf.bytes-ref view 2)
          101
          "byte-buf view reads live data")))
    (let
      [buf : byte_buf.ByteBuf (byte_buf.byte-buf-from-string "abc")]
      (begin
        (let
          [view : (&mut buf bytes) (byte_buf.byte-buf-as-mut-bytes (&mut buf))]
          (begin
            (test.assert-i64-eq
              (byte_buf.bytes-mut-length view)
              3
              "mutable bytes len")
            (assert-u8-eq
              (byte_buf.bytes-mut-ref view 0)
              97
              "mutable bytes read")
            (byte_buf.bytes-set! view 1 (make-u8 90))
            (let
              [tail : (&mut buf bytes) (byte_buf.bytes-mut-slice-view view 2 1)]
              (byte_buf.bytes-set! tail 0 (make-u8 81)))))
        (assert-u8-eq
          (byte_buf.byte-buf-ref buf 1)
          90
          "mutable bytes writes through")
        (assert-u8-eq
          (byte_buf.byte-buf-ref buf 2)
          81
          "mutable bytes sub-slice writes through")))))

(define (assert-binary-string) : unit
  (let
    [binary : byte_buf.ByteBuf
      (byte_buf.byte-buf-push
        (byte_buf.byte-buf-push
          (byte_buf.byte-buf-push (byte_buf.byte-buf-new) (make-u8 0))
          (make-u8 128))
        (make-u8 255))]
    [text : String (byte_buf.byte-buf-to-string binary)]
    (begin
      (test.assert-i64-eq (string-length text) 3 "binary string length")
      (assert-u8-eq (string-byte text 0) 0 "binary nul byte")
      (assert-u8-eq (string-byte text 1) 128 "binary high byte")
      (assert-u8-eq (string-byte text 2) 255 "binary max byte"))))

(define (assert-legacy-public-api) : unit
  (let
    [src : (Array u8) (array.make-array u8 4)]
    (begin
      (array.array-set! src 0 (make-u8 65))
      (array.array-set! src 1 (make-u8 0))
      (array.array-set! src 2 (make-u8 128))
      (array.array-set! src 3 (make-u8 255))
      (let
        [buf : byte_buf.ByteBuf
          (byte_buf.byte-buf-append-string
            (byte_buf.byte-buf-append-array
              (byte_buf.byte-buf-with-capacity 1)
              src)
            "ok")]
        (begin
          (test.assert-i64-eq (byte_buf.byte-buf-len buf) 6 "append len")
          (test.assert-true
            (>= (byte_buf.byte-buf-capacity buf) 6)
            "append capacity")
          (assert-u8-eq (byte_buf.byte-buf-ref buf 0) 65 "first byte")
          (assert-u8-eq (byte_buf.byte-buf-ref buf 1) 0 "nul byte")
          (assert-u8-eq (byte_buf.byte-buf-ref buf 2) 128 "high byte")
          (assert-u8-eq (byte_buf.byte-buf-ref buf 3) 255 "max byte")
          (assert-u8-eq (byte_buf.byte-buf-ref buf 4) 111 "string o")
          (assert-u8-eq (byte_buf.byte-buf-ref buf 5) 107 "string k")
          (let
            [snap : (Array u8) (byte_buf.byte-buf-to-array buf)]
            (begin
              (test.assert-i64-eq (array.array-length snap) 6 "snapshot len")
              (array.array-set! snap 0 (make-u8 1))
              (assert-u8-eq (byte_buf.byte-buf-ref buf 0) 65 "snapshot copies")))
          (let
            [text-buf : byte_buf.ByteBuf (byte_buf.byte-buf-from-string "text")]
            [text : String (byte_buf.byte-buf-to-string text-buf)]
            [expected : String "text"]
            (begin
              (test.assert-string-eq (& text) (& expected) "string round trip")
              (test.assert-true
                (byte_buf.byte-buf-empty? (byte_buf.byte-buf-clear! text-buf))
                "clear empties buffer"))))))))

(define (main) : i64
  (begin
    (assert-basic-growth)
    (assert-array-copy)
    (assert-mixed-append)
    (assert-string-roundtrip)
    (assert-borrowed-bytes)
    (assert-byte-buf-views)
    (assert-binary-string)
    (assert-legacy-public-api)
    42))