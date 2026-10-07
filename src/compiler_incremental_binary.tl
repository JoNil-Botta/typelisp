;; compiler_incremental_binary.tl - bounded primitives for incremental query
;; identity transcripts.
;;
;; The query schema lives in compiler_incremental_identity.tl. Integers use
;; stdlib.byte_le and the checked cursor is a stdlib.byte_reader; this leaf adds
;; the owned-byte and string limits, exact byte comparisons, and portable
;; text/path validation. It deliberately does not import compiler state,
;; filesystem access, or cache storage.
(import stdlib.iterator)
(import stdlib.byte_buf_core)
(import stdlib.byte_le)
(import stdlib.byte_reader)
(import stdlib.string)

;; The cursor's own failures (byte_reader.error-truncated and
;; error-work-limit) are reported as the identity schema's truncated and
;; work-limit errors; every other code is the schema's own.
(defstruct CompilerIncrementalBinaryReader
  (cursor byte_reader.ByteReader)
  (owned-bytes i64)
  (max-owned-bytes i64)
  (max-string-bytes i64))

(define (compiler-incremental-binary-copy
  [bytes : (& bytes (__tl_dyn-array u8))]) : (__tl_dyn-array u8)
  (let
    [out : (__tl_dyn-array u8) (__tl_make-array u8 (array-length bytes))]
    (for [index (iterator.range 0 (array-length bytes))]
      (set! (array-ref out index) (array-ref bytes index)))
    out))

(define (compiler-incremental-binary-reader
  [bytes : (& bytes (__tl_dyn-array u8))]
  [max-work : i64]
  [max-owned-bytes : i64]
  [max-string-bytes : i64]) : CompilerIncrementalBinaryReader
  (let
    [length : i64 (array-length bytes)]
    (if (> length max-owned-bytes)
      (let
        [cursor : byte_reader.ByteReader
          (byte_reader.new (__tl_make-array u8 0) max-work)]
        (byte_reader.fail!
          (&mut cursor)
          8
          0
          "incremental identity owned-byte limit exceeded")
        (CompilerIncrementalBinaryReader
          cursor
          0
          max-owned-bytes
          max-string-bytes))
      (CompilerIncrementalBinaryReader
        (byte_reader.new (compiler-incremental-binary-copy bytes) max-work)
        length
        max-owned-bytes
        max-string-bytes))))

(define (compiler-incremental-binary-fail!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]
  [code : i64]
  [offset : i64]
  [message : String]) : unit
  (byte_reader.fail! (&mut reader.cursor) code offset message))

(define (compiler-incremental-binary-push-u8!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [value : i64]) : unit
  (byte_buf_core.byte-buf-builder-push out (cast value : u8)))

(define (compiler-incremental-binary-push-string!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [text : (& text str)]) : unit
  (let
    [length : i64 (string.string-length text)]
    (byte_le.push-u32! out length)
    (for [index (iterator.range 0 length)]
      (byte_buf_core.byte-buf-builder-push
        out
        (cast (string.string-ref text index) : u8)))))

(define (compiler-incremental-binary-push-array!
  [out : (&mut out byte_buf_core.ByteBufBuilder)]
  [bytes : (& bytes (__tl_dyn-array u8))]) : unit
  (byte_buf_core.byte-buf-builder-append-array out bytes))

;; Validate Unicode scalar UTF-8.  Overlong encodings, surrogate scalars, NUL,
;; and values above U+10ffff are rejected so one logical spelling has one byte
;; representation at this boundary.
;;
;; A lead byte fixes the sequence length and the one range its second byte may
;; take (Unicode Table 3-7): 0xe0 and 0xf0 exclude the overlong low halves, 0xed
;; the surrogates and 0xf4 everything above U+10ffff; every later byte is a
;; plain continuation 0x80..0xbf. A sequence is read only once it fits before
;; `end`.
(define (compiler-incremental-binary-utf8-range-valid?
  [bytes : (& bytes (__tl_dyn-array u8))]
  [start : i64]
  [length : i64]) : bool
  (let
    [index : i64 start]
    [end : i64 (+ start length)]
    [ok? : bool (byte_reader.range-present? (array-length bytes) start length)]
    (while (and ok? (< index end))
      (let
        [first : i64 (cast (array-ref bytes index) : i64)]
        [count : i64
          (cond
            [(and (>= first 1) (<= first 0x7f)) 1]
            [(and (>= first 0xc2) (<= first 0xdf)) 2]
            [(and (>= first 0xe0) (<= first 0xef)) 3]
            [(and (>= first 0xf0) (<= first 0xf4)) 4]
            [else 0])]
        [low : i64
          (cond [(= first 0xe0) 0xa0] [(= first 0xf0) 0x90] [else 0x80])]
        [high : i64
          (cond [(= first 0xed) 0x9f] [(= first 0xf4) 0x8f] [else 0xbf])]
        [k : i64 1]
        (set! ok? (and (> count 0) (<= (+ index count) end)))
        (while (and ok? (< k count))
          (let
            [byte : i64 (cast (array-ref bytes (+ index k)) : i64)]
            (set! ok? (and (>= byte low) (<= byte high)))
            (set! low 0x80)
            (set! high 0xbf)
            (+= k 1)))
        (+= index count)))
    ok?))

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
                  (+= index 1))))]
          [else (+= index 1)])))
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
      false)))

(define (compiler-incremental-binary-read-string!
  [reader : (&mut reader CompilerIncrementalBinaryReader)]
  [path? : bool]) : String
  (let
    [length-offset : i64 reader.cursor.offset]
    [length : i64 (byte_reader.read-u32! (&mut reader.cursor))]
    [start : i64 reader.cursor.offset]
    (cond
      [(not reader.cursor.ok?) ""]
      [(> length reader.max-string-bytes)
        (compiler-incremental-binary-fail!
          reader
          7
          length-offset
          "incremental identity string limit exceeded")
        ""]
      [(not (byte_reader.consume! (&mut reader.cursor) length)) ""]
      [(not (byte_reader.consume! (&mut reader.cursor) length)) ""]
      [(not
        (compiler-incremental-binary-utf8-range-valid?
          (& reader.cursor.bytes)
          start
          length))
        (compiler-incremental-binary-fail!
          reader
          11
          start
          "incremental identity text is not canonical UTF-8")
        ""]
      [(if path?
        (if (byte_reader.consume! (&mut reader.cursor) length)
          (not
            (compiler-incremental-binary-path-range-valid?
              (& reader.cursor.bytes)
              start
              length))
          true)
        false)
        (compiler-incremental-binary-fail!
          reader
          12
          start
          "incremental identity path is not canonical relative UTF-8")
        ""]
      [(> length (- reader.max-owned-bytes reader.owned-bytes))
        (compiler-incremental-binary-fail!
          reader
          8
          start
          "incremental identity owned-byte limit exceeded")
        ""]
      [else
        (let
          [out : (__tl_dyn-array u8) (__tl_make-array u8 length)]
          (for [index (iterator.range 0 length)]
            (set!
              (array-ref out index)
              (array-ref reader.cursor.bytes (+ start index))))
          (set! reader.cursor.offset (+ start length))
          (+= reader.owned-bytes length)
          (unsafe
            (string-from-bytes
              (ptr-cast (__tl_array-data out) : (Ptr u8))
              length)))])))

(define (compiler-incremental-binary-bytes-eq?
  [left : (& left (__tl_dyn-array u8))]
  [right : (& right (__tl_dyn-array u8))]) : bool
  (let
    [equal? : bool (= (array-length left) (array-length right))]
    [index : i64 0]
    (while (and equal? (< index (array-length left)))
      (if (= (array-ref left index) (array-ref right index))
        unit
        (set! equal? false))
      (+= index 1))
    equal?))