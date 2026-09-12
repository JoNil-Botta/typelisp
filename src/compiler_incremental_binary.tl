;; compiler_incremental_binary.tl - bounded primitives for incremental query
;; identity transcripts.
;;
;; The query schema lives in compiler_incremental_identity.tl.  This leaf owns
;; only its little-endian framing, checked cursor, exact byte comparisons, and
;; portable text/path validation.  It deliberately does not import compiler
;; state, filesystem access, or cache storage.
(import stdlib.byte_buf_core)
(import stdlib.string)

(defstruct CompilerIncrementalBinaryReader
  (bytes (__tl_dyn-array u8))
  (offset i64)
  (end i64)
  (ok? bool)
  (error-code i64)
  (error-offset i64)
  (error-message String)
  (work i64)
  (max-work i64)
  (owned-bytes i64)
  (max-owned-bytes i64)
  (max-string-bytes i64))

(define (compiler-incremental-binary-copy
  [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
    [index : i64 0]
    (begin
      (while (< index (array-length bytes))
        (begin
          (set! (array-ref out index) (array-ref bytes index))
          (set! index (+ index 1))))
      out)))

(define (compiler-incremental-binary-reader
  [bytes : (& bytes (__tl_dyn-array u8))]
  [max-work : i64]
  [max-owned-bytes : i64]
  [max-string-bytes : i64]) : CompilerIncrementalBinaryReader
  (let
    [length : i64 (array-length bytes)]
    (if (> length max-owned-bytes)
      (CompilerIncrementalBinaryReader
        (__tl_make-array u8 0)
        0
        0
        false
        8
        0
        "incremental identity owned-byte limit exceeded"
        0
        max-work
        0
        max-owned-bytes
        max-string-bytes)
      (CompilerIncrementalBinaryReader
        (compiler-incremental-binary-copy bytes)
        0
        length
        true
        0
        0
        ""
        0
        max-work
        length
        max-owned-bytes
        max-string-bytes))))

(define (compiler-incremental-binary-fail!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (if reader.ok?
    (begin
      (set! reader.ok? false)
      (set! reader.error-code code)
      (set! reader.error-offset offset)
      (set! reader.error-message message))
    unit))

(define (compiler-incremental-binary-range-present?
  [length : i64]
  [start : i64]
  [count : i64]) : bool
  (and (>= start 0) (>= count 0) (<= start length) (<= count (- length start))))

(define (compiler-incremental-binary-consume!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]
  [count : i64]) : bool
  (cond
    [(not reader.ok?) false]
    [(not
        (compiler-incremental-binary-range-present?
          reader.end
          reader.offset
          count))
      (begin
        (compiler-incremental-binary-fail!
          reader
          3
          reader.offset
          "incremental identity transcript is truncated")
        false)]
    [(> count (- reader.max-work reader.work))
      (begin
        (compiler-incremental-binary-fail!
          reader
          9
          reader.offset
          "incremental identity work limit exceeded")
        false)]
    [else
      (begin
        (set! reader.work (+ reader.work count))
        true)]))

(define (compiler-incremental-binary-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast value : u8)))

(define (compiler-incremental-binary-push-u32!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [bits : u64 (cast value : u64)]
    [index : i64 0]
    (while (< index 4)
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (cast
            (bit-and (shr bits (cast (* index 8) : u64)) (cast 255 : u64))
            : u8))
        (set! index (+ index 1))))))

(define (compiler-incremental-binary-push-u64!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (let
    [bits : u64 (cast value : u64)]
    [index : i64 0]
    (while (< index 8)
      (begin
        (byte_buf_core.byte-buf-builder-push
          out
          (cast
            (bit-and (shr bits (cast (* index 8) : u64)) (cast 255 : u64))
            : u8))
        (set! index (+ index 1))))))

(define (compiler-incremental-binary-push-string!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [length : i64 (string.string-length text)]
    [index : i64 0]
    (begin
      (compiler-incremental-binary-push-u32! out length)
      (while (< index length)
        (begin
          (byte_buf_core.byte-buf-builder-push
            out
            (cast (string.string-ref text index) : u8))
          (set! index (+ index 1)))))))

(define (compiler-incremental-binary-push-array!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [bytes : (& bytes (__tl_dyn-array u8))]) : unit
  (byte_buf_core.byte-buf-builder-append-array out bytes))

(define (compiler-incremental-binary-read-u8!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]) : i64
  (if (compiler-incremental-binary-consume! reader 1)
    (let
      [offset : i64 reader.offset]
      (begin
        (set! reader.offset (+ offset 1))
        (cast (array-ref reader.bytes offset) : i64)))
    0))

(define (compiler-incremental-binary-read-u32!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]) : i64
  (if (compiler-incremental-binary-consume! reader 4)
    (let
      [offset : i64 reader.offset]
      [value : i64 0]
      [index : i64 0]
      (begin
        (while (< index 4)
          (begin
            (set!
              value
              (bit-or
                value
                (shl
                  (cast (array-ref reader.bytes (+ offset index)) : i64)
                  (* index 8))))
            (set! index (+ index 1))))
        (set! reader.offset (+ offset 4))
        value))
    0))

(define (compiler-incremental-binary-read-u64!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]) : i64
  (if (compiler-incremental-binary-consume! reader 8)
    (let
      [offset : i64 reader.offset]
      [value : u64 (cast 0 : u64)]
      [index : i64 0]
      (begin
        (while (< index 8)
          (begin
            (set!
              value
              (bit-or
                value
                (shl
                  (cast (array-ref reader.bytes (+ offset index)) : u64)
                  (cast (* index 8) : u64))))
            (set! index (+ index 1))))
        (set! reader.offset (+ offset 8))
        (cast value : i64)))
    0))

(define (compiler-incremental-binary-continuation? [byte : i64]) : bool
  (and (>= byte 0x80) (<= byte 0xbf)))

;; Validate Unicode scalar UTF-8.  Overlong encodings, surrogate scalars, NUL,
;; and values above U+10ffff are rejected so one logical spelling has one byte
;; representation at this boundary.
(define (compiler-incremental-binary-utf8-range-valid?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : bool
  (let
    [index : i64 start]
    [end : i64 (+ start length)]
    [ok? : bool
      (compiler-incremental-binary-range-present?
        (array-length bytes)
        start
        length)]
    (begin
      (while (and ok? (< index end))
        (let
          [first : i64 (cast (array-ref bytes index) : i64)]
          (cond
            [(and (>= first 1) (<= first 0x7f)) (set! index (+ index 1))]
            [(and (>= first 0xc2) (<= first 0xdf))
              (if (and
                (< (+ index 1) end)
                (compiler-incremental-binary-continuation?
                  (cast (array-ref bytes (+ index 1)) : i64)))
                (set! index (+ index 2))
                (set! ok? false))]
            [(and (>= first 0xe0) (<= first 0xef))
              (if (< (+ index 2) end)
                (let
                  [second : i64 (cast (array-ref bytes (+ index 1)) : i64)]
                  [third : i64 (cast (array-ref bytes (+ index 2)) : i64)]
                  (if (and
                    (compiler-incremental-binary-continuation? third)
                    (if (= first 0xe0)
                      (and (>= second 0xa0) (<= second 0xbf))
                      (if (= first 0xed)
                        (and (>= second 0x80) (<= second 0x9f))
                        (compiler-incremental-binary-continuation? second))))
                    (set! index (+ index 3))
                    (set! ok? false)))
                (set! ok? false))]
            [(and (>= first 0xf0) (<= first 0xf4))
              (if (< (+ index 3) end)
                (let
                  [second : i64 (cast (array-ref bytes (+ index 1)) : i64)]
                  [third : i64 (cast (array-ref bytes (+ index 2)) : i64)]
                  [fourth : i64 (cast (array-ref bytes (+ index 3)) : i64)]
                  (if (and
                    (compiler-incremental-binary-continuation? third)
                    (compiler-incremental-binary-continuation? fourth)
                    (if (= first 0xf0)
                      (and (>= second 0x90) (<= second 0xbf))
                      (if (= first 0xf4)
                        (and (>= second 0x80) (<= second 0x8f))
                        (compiler-incremental-binary-continuation? second))))
                    (set! index (+ index 4))
                    (set! ok? false)))
                (set! ok? false))]
            [else (set! ok? false)])))
      ok?)))

(define (compiler-incremental-binary-path-range-valid?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : bool
  (let
    [end : i64 (+ start length)]
    [index : i64 start]
    [segment-start : i64 start]
    [ok? : bool
      (and
        (> length 0)
        (compiler-incremental-binary-utf8-range-valid? bytes start length))]
    (begin
      (if ok?
        (let
          [first : i64 (cast (array-ref bytes start) : i64)]
          (if (or (= first 47) (= first 92))
            (set! ok? false)
            unit))
        unit)
      (while (and ok? (< index end))
        (let
          [byte : i64 (cast (array-ref bytes index) : i64)]
          (cond
            [(or (= byte 0) (= byte 92) (= byte 58)) (set! ok? false)]
            [(= byte 47)
              (let
                [segment-length : i64 (- index segment-start)]
                (if (or
                  (= segment-length 0)
                  (and
                    (= segment-length 1)
                    (= (array-ref bytes segment-start) (cast 46 : u8)))
                  (and
                    (= segment-length 2)
                    (= (array-ref bytes segment-start) (cast 46 : u8))
                    (= (array-ref bytes (+ segment-start 1)) (cast 46 : u8))))
                  (set! ok? false)
                  (begin
                    (set! segment-start (+ index 1))
                    (set! index (+ index 1)))))]
            [else (set! index (+ index 1))])))
      (if ok?
        (let
          [segment-length : i64 (- end segment-start)]
          (not
            (or
              (= segment-length 0)
              (and
                (= segment-length 1)
                (= (array-ref bytes segment-start) (cast 46 : u8)))
              (and
                (= segment-length 2)
                (= (array-ref bytes segment-start) (cast 46 : u8))
                (= (array-ref bytes (+ segment-start 1)) (cast 46 : u8))))))
        false))))

(define (compiler-incremental-binary-read-string!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]
  [path? : bool]) : String
  (let
    [length-offset : i64 reader.offset]
    [length : i64 (compiler-incremental-binary-read-u32! reader)]
    [start : i64 reader.offset]
    (cond
      [(not reader.ok?) ""]
      [(> length reader.max-string-bytes)
        (begin
          (compiler-incremental-binary-fail!
            reader
            7
            length-offset
            "incremental identity string limit exceeded")
          "")]
      [(not (compiler-incremental-binary-consume! reader length)) ""]
      [(not (compiler-incremental-binary-consume! reader length)) ""]
      [(not
          (compiler-incremental-binary-utf8-range-valid?
            (& reader.bytes)
            start
            length))
        (begin
          (compiler-incremental-binary-fail!
            reader
            11
            start
            "incremental identity text is not canonical UTF-8")
          "")]
      [(if path?
          (if (compiler-incremental-binary-consume! reader length)
            (not
              (compiler-incremental-binary-path-range-valid?
                (& reader.bytes)
                start
                length))
            true)
          false)
        (begin
          (compiler-incremental-binary-fail!
            reader
            12
            start
            "incremental identity path is not canonical relative UTF-8")
          "")]
      [(> length (- reader.max-owned-bytes reader.owned-bytes))
        (begin
          (compiler-incremental-binary-fail!
            reader
            8
            start
            "incremental identity owned-byte limit exceeded")
          "")]
      [else
        (let
          [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
          [index : i64 0]
          (begin
            (while (< index length)
              (begin
                (set!
                  (array-ref out index)
                  (array-ref reader.bytes (+ start index)))
                (set! index (+ index 1))))
            (set! reader.offset (+ start length))
            (set! reader.owned-bytes (+ reader.owned-bytes length))
            (unsafe
              (string-from-bytes
                (ptr-cast (__tl_array-data out) : (Ptr u8))
                length))))])))

(define (compiler-incremental-binary-bytes-eq?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [equal? : bool (= (array-length left) (array-length right))]
    [index : i64 0]
    (begin
      (while (and equal? (< index (array-length left)))
        (begin
          (if (= (array-ref left index) (array-ref right index))
            unit
            (set! equal? false))
          (set! index (+ index 1))))
      equal?)))

(define (compiler-incremental-binary-bytes-less?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [limit : i64
      (if (< (array-length left) (array-length right))
        (array-length left)
        (array-length right))]
    [index : i64 0]
    [decided? : bool false]
    [less? : bool false]
    (begin
      (while (and (not decided?) (< index limit))
        (let
          [left-byte : u8 (array-ref left index)]
          [right-byte : u8 (array-ref right index)]
          (cond
            [(< left-byte right-byte)
              (begin
                (set! less? true)
                (set! decided? true))]
            [(> left-byte right-byte) (set! decided? true)]
            [else (set! index (+ index 1))])))
      (if decided?
        less?
        (< (array-length left) (array-length right))))))