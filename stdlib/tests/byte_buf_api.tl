(import stdlib.byte_buf)
(import stdlib.string)
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
      [empty : byte_buf.ByteBuf (byte_buf.with-capacity 2)]
      (begin
        (test.assert-i64-eq (byte_buf.len empty) 0 "empty len")
        (test.assert-i64-eq (byte_buf.length empty) 0 "empty length alias")
        (test.assert-i64-eq (byte_buf.capacity empty) 2 "empty capacity")
        (test.assert-true (byte_buf.empty? empty) "empty predicate")
        (assert-u8-eq
          (byte_buf.get empty 0 (make-u8 77))
          77
          "empty get fallback")))
    (test.assert-i64-eq
      (byte_buf.capacity (byte_buf.with-capacity 0))
      1
      "zero capacity clamps")
    (let
      [buf : byte_buf.ByteBuf (byte_buf.with-capacity 2)]
      (begin
        (set! buf (byte_buf.push buf (make-u8 10)))
        (set! buf (byte_buf.push buf (make-u8 20)))
        (test.assert-i64-eq (byte_buf.len buf) 2 "push len")
        (test.assert-i64-eq (byte_buf.capacity buf) 2 "push no growth")
        (assert-u8-eq (byte_buf.ref buf 0) 10 "ref first")
        (assert-u8-eq (byte_buf.ref buf 1) 20 "ref second")
        (set! buf (byte_buf.push buf (make-u8 30)))
        (test.assert-i64-eq (byte_buf.len buf) 3 "growth push len")
        (test.assert-i64-eq (byte_buf.capacity buf) 4 "growth capacity")
        (assert-u8-eq (byte_buf.ref buf 2) 30 "growth value")
        (set! buf (byte_buf.set! buf 1 (make-u8 99)))
        (assert-u8-eq (byte_buf.ref buf 1) 99 "set value")
        (set! buf (byte_buf.reserve buf 5))
        (test.assert-i64-eq (byte_buf.len buf) 3 "reserve keeps len")
        (test.assert-true (>= (byte_buf.capacity buf) 8) "reserve grows enough")
        (set! buf (byte_buf.clear! buf))
        (test.assert-true (byte_buf.empty? buf) "clear empties")
        (set! buf (byte_buf.push buf (make-u8 7)))
        (test.assert-i64-eq (byte_buf.len buf) 1 "reuse after clear")
        (assert-u8-eq (byte_buf.ref buf 0) 7 "reuse value")))))

(define (assert-borrowed-copy) : unit
  (let
    [src : byte_buf.ByteBuf
      (byte_buf.push
        (byte_buf.push
          (byte_buf.push (byte_buf.push (byte_buf.new) (make-u8 1)) (make-u8 0))
          (make-u8 200))
        (make-u8 255))]
    [view : (& src bytes) (byte_buf.as-bytes (& src))]
    [buf : byte_buf.ByteBuf (byte_buf.from-bytes view)]
    (begin
      (test.assert-i64-eq (byte_buf.len buf) 4 "from-bytes len")
      (assert-u8-eq (byte_buf.ref buf 2) 200 "from-bytes copies")
      (let
        [slice : byte_buf.ByteBuf (byte_buf.from-bytes-range view 1 2)]
        (begin
          (test.assert-i64-eq (byte_buf.len slice) 2 "range copy len")
          (assert-u8-eq (byte_buf.ref slice 0) 0 "range copy first")
          (assert-u8-eq (byte_buf.ref slice 1) 200 "range copy second"))))))

(define (assert-mixed-append) : unit
  (let
    [src : String "ABC"]
    [view : (& src bytes) (byte_buf.str-as-bytes (& src))]
    [buf : byte_buf.ByteBuf
      (byte_buf.append-bytes-range
        (byte_buf.append-string (byte_buf.new) "xy")
        view
        1
        2)]
    (begin
      (let
        [actual : String (byte_buf.to-string buf)]
        [expected : String "xyBC"]
        (test.assert-string-eq
          (& actual)
          (& expected)
          "append string and bytes range"))
      (test.assert-i64-eq (byte_buf.len buf) 4 "append mixed len"))))

(define (assert-string-roundtrip) : unit
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "hello")]
    (begin
      (test.assert-i64-eq (byte_buf.len buf) 5 "from-string len")
      (assert-u8-eq (byte_buf.ref buf 1) 101 "from-string e")
      (let
        [out : String (byte_buf.to-string buf)]
        [expected : String "hello"]
        (test.assert-string-eq (& out) (& expected) "to-string text")))))

(define (assert-string-copy-boundaries) : unit
  (begin
    (let
      [buf : byte_buf.ByteBuf (byte_buf.from-string "owner")]
      [copy : String (byte_buf.to-string buf)]
      [expected : String "owner"]
      (begin
        (set! buf (byte_buf.set! buf 0 (make-u8 88)))
        (test.assert-string-eq
          (& copy)
          (& expected)
          "to-string owns copied storage")))
    (let
      [buf : byte_buf.ByteBuf (byte_buf.from-string "borrow")]
      [copy : String
        (let
          [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
          (byte_buf.bytes-to-string view))]
      [expected : String "borrow"]
      (begin
        (set! buf (byte_buf.set! buf 0 (make-u8 88)))
        (test.assert-string-eq
          (& copy)
          (& expected)
          "bytes-to-string owns copied storage")))))

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
        [copy : String (byte_buf.bytes-to-string middle)]
        [expected : String "cde"]
        (test.assert-string-eq (& copy) (& expected) "bytes to-string"))
      (let
        [buf : byte_buf.ByteBuf (byte_buf.from-bytes middle)]
        [actual : String (byte_buf.to-string buf)]
        [expected : String "cde"]
        (test.assert-string-eq (& actual) (& expected) "byte-buf from bytes"))
      (let
        [buf : byte_buf.ByteBuf
          (byte_buf.append-bytes (byte_buf.from-string "x") middle)]
        [actual : String (byte_buf.to-string buf)]
        [expected : String "xcde"]
        (test.assert-string-eq (& actual) (& expected) "byte-buf append bytes")))))

(define (assert-byte-buf-views) : unit
  (begin
    (let
      [buf : byte_buf.ByteBuf (byte_buf.from-string "view")]
      [view : (& buf bytes) (byte_buf.as-bytes (& buf))]
      (begin
        (test.assert-i64-eq (byte_buf.bytes-length view) 4 "byte-buf view len")
        (assert-u8-eq
          (byte_buf.bytes-ref view 2)
          101
          "byte-buf view reads live data")))
    (let
      [buf : byte_buf.ByteBuf (byte_buf.from-string "abc")]
      (begin
        (let
          [view : (&mut buf bytes) (byte_buf.as-mut-bytes (&mut buf))]
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
        (assert-u8-eq (byte_buf.ref buf 1) 90 "mutable bytes writes through")
        (assert-u8-eq
          (byte_buf.ref buf 2)
          81
          "mutable bytes sub-slice writes through")))))

(define (assert-binary-string) : unit
  (let
    [binary : byte_buf.ByteBuf
      (byte_buf.push
        (byte_buf.push (byte_buf.push (byte_buf.new) (make-u8 0)) (make-u8 128))
        (make-u8 255))]
    [text : String (byte_buf.to-string binary)]
    (begin
      (test.assert-i64-eq (string.string-length text) 3 "binary string length")
      (assert-u8-eq (string-byte text 0) 0 "binary nul byte")
      (assert-u8-eq (string-byte text 1) 128 "binary high byte")
      (assert-u8-eq (string-byte text 2) 255 "binary max byte"))))

(define (assert-public-copy-api) : unit
  (let
    [src : byte_buf.ByteBuf
      (byte_buf.push
        (byte_buf.push
          (byte_buf.push
            (byte_buf.push (byte_buf.new) (make-u8 65))
            (make-u8 0))
          (make-u8 128))
        (make-u8 255))]
    [view : (& src bytes) (byte_buf.as-bytes (& src))]
    [buf : byte_buf.ByteBuf
      (byte_buf.append-string (byte_buf.from-bytes view) "ok")]
    (begin
      (test.assert-i64-eq (byte_buf.len buf) 6 "append len")
      (test.assert-true (>= (byte_buf.capacity buf) 6) "append capacity")
      (assert-u8-eq (byte_buf.ref buf 0) 65 "first byte")
      (assert-u8-eq (byte_buf.ref buf 1) 0 "nul byte")
      (assert-u8-eq (byte_buf.ref buf 2) 128 "high byte")
      (assert-u8-eq (byte_buf.ref buf 3) 255 "max byte")
      (assert-u8-eq (byte_buf.ref buf 4) 111 "string o")
      (assert-u8-eq (byte_buf.ref buf 5) 107 "string k")
      (let
        [text-buf : byte_buf.ByteBuf (byte_buf.from-string "text")]
        [text : String (byte_buf.to-string text-buf)]
        [expected : String "text"]
        (begin
          (test.assert-string-eq (& text) (& expected) "string round trip")
          (test.assert-true
            (byte_buf.empty? (byte_buf.clear! text-buf))
            "clear empties buffer"))))))

(define (main) : i64
  (begin
    (assert-basic-growth)
    (assert-borrowed-copy)
    (assert-mixed-append)
    (assert-string-roundtrip)
    (assert-string-copy-boundaries)
    (assert-borrowed-bytes)
    (assert-byte-buf-views)
    (assert-binary-string)
    (assert-public-copy-api)
    42))