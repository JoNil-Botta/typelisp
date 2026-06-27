(import stdlib.byte_buf_core)
(import stdlib.test)

(define (assert-u8-eq [actual : u8] [expected : i64] [message : String]) : unit
  (test.assert-i64-eq (cast actual : i64) expected message))

(define (make-u8 [value : i64]) : u8
  (cast value : u8))

(define (string-byte [text : String] [index : i64]) : u8
  (unsafe
    (ptr-read (ptr-offset (string-data (& text)) index))))

(define (assert-core-builder) : unit
  (let
    [buf : byte_buf_core.ByteBufBuilder
      (byte_buf_core.byte-buf-builder-with-capacity 2)]
    [src : (Array u8) (make-array u8 4)]
    (begin
      (test.assert-i64-eq
        (byte_buf_core.byte-buf-builder-len (& buf))
        0
        "empty len")
      (test.assert-i64-eq
        (byte_buf_core.byte-buf-builder-capacity (& buf))
        2
        "empty capacity")
      (test.assert-true
        (byte_buf_core.byte-buf-builder-empty? (& buf))
        "empty predicate")
      (byte_buf_core.byte-buf-builder-push (&mut buf) (make-u8 65))
      (byte_buf_core.byte-buf-builder-push (&mut buf) (make-u8 0))
      (byte_buf_core.byte-buf-builder-push (&mut buf) (make-u8 128))
      (test.assert-i64-eq
        (byte_buf_core.byte-buf-builder-len (& buf))
        3
        "push len")
      (test.assert-true
        (>= (byte_buf_core.byte-buf-builder-capacity (& buf)) 4)
        "push grows")
      (array-set! src 0 (make-u8 1))
      (array-set! src 1 (make-u8 200))
      (array-set! src 2 (make-u8 255))
      (array-set! src 3 (make-u8 2))
      (byte_buf_core.byte-buf-builder-append-array-range (&mut buf) (& src) 1 2)
      (byte_buf_core.byte-buf-builder-append-string (&mut buf) "ok")
      (test.assert-i64-eq
        (byte_buf_core.byte-buf-builder-length (& buf))
        7
        "append len alias")
      (byte_buf_core.byte-buf-builder-reserve (&mut buf) 20)
      (test.assert-i64-eq
        (byte_buf_core.byte-buf-builder-len (& buf))
        7
        "reserve keeps len")
      (let
        [snap : (Array u8)
          (byte_buf_core.byte-buf-builder-finish-array (& buf))]
        (begin
          (test.assert-i64-eq (array-length snap) 7 "snapshot len")
          (assert-u8-eq (array-ref snap 0) 65 "snapshot first")
          (assert-u8-eq (array-ref snap 1) 0 "snapshot nul")
          (assert-u8-eq (array-ref snap 2) 128 "snapshot high")
          (assert-u8-eq (array-ref snap 3) 200 "snapshot array high")
          (assert-u8-eq (array-ref snap 4) 255 "snapshot max")
          (assert-u8-eq (array-ref snap 5) 111 "snapshot string o")
          (assert-u8-eq (array-ref snap 6) 107 "snapshot string k")
          (array-set! snap 0 (make-u8 7))
          (let
            [again : (Array u8)
              (byte_buf_core.byte-buf-builder-copy-range (& buf) 0 1)]
            (assert-u8-eq (array-ref again 0) 65 "snapshot copies"))))
      (let
        [text : String (byte_buf_core.byte-buf-builder-finish-string (& buf))]
        (begin
          (test.assert-i64-eq (string-length text) 7 "string length")
          (assert-u8-eq (string-byte text 1) 0 "string nul")
          (assert-u8-eq (string-byte text 2) 128 "string high")
          (assert-u8-eq (string-byte text 4) 255 "string max")
          (assert-u8-eq (string-byte text 5) 111 "string o"))))))

(define (main) : i64
  (begin
    (assert-core-builder)
    42))