(import stdlib.byte_buf)
(import stdlib.format)
(import stdlib.profile)
(import stdlib.string)
(import stdlib.string_utf8 as utf8)
(import stdlib.test)

(define (input-bytes [a : i64] [b : i64] [c : i64] [d : i64]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "A")]
    (set! buf (byte_buf.push buf (cast a : u8)))
    (set! buf (byte_buf.push buf (cast b : u8)))
    (set! buf (byte_buf.push buf (cast c : u8)))
    (set! buf (byte_buf.push buf (cast d : u8)))
    (byte_buf.to-string buf)))

(define (kind-code [kind : utf8.ErrorKind]) : i64
  (match kind
    [(InvalidOffset) 0]
    [(InvalidLead) 1]
    [(UnexpectedContinuation) 2]
    [(Truncated) 3]
    [(InvalidContinuation) 4]
    [(Overlong) 5]
    [(Surrogate) 6]
    [(OutOfRange) 7]))

(define (assert-error
  [error : utf8.DecodeError]
  [kind : i64]
  [start : i64]
  [failure : i64]) : unit
  (test.assert-i64-eq (kind-code error.kind) kind "UTF-8 error kind")
  (test.assert-i64-eq error.sequence-start start "UTF-8 sequence start")
  (test.assert-i64-eq error.failure-offset failure "UTF-8 failure offset"))

(define (expect-error [input : (& input str)] [kind : i64] [failure : i64]) : unit
  (match (utf8.decode-at input 1)
    [(Error error) (assert-error error kind 1 failure)]
    [_ (test.assert-true false "decode must reject")])
  (match (utf8.validate input)
    [(Invalid error) (assert-error error kind 1 failure)]
    [_ (test.assert-true false "validator must return the same first error")]))

(define (expect-scalar
  [input : (& input str)]
  [offset : i64]
  [value : i64]
  [next : i64]) : unit
  (match (utf8.decode-at input offset)
    [(Scalar scalar actual-next)
      (test.assert-i64-eq (cast scalar.value : i64) value "scalar value")
      (test.assert-i64-eq actual-next next "next byte offset")
      (test.assert-true (> actual-next offset) "strict forward progress")]
    [_ (test.assert-true false "expected decoded scalar")]))

(define (expect-valid [input : (& input str)]) : unit
  (match (utf8.validate input)
    [(Valid) unit]
    [_ (test.assert-true false "expected valid UTF-8")]))

(define (assert-boundaries) : unit
  (let
    [rows : (Array (Array i64 6) 18)
      (array
        (array 0 0 0 0 1 0)
        (array 0x7f 0 0 0 1 0x7f)
        (array 0xc2 0x80 0 0 2 0x80)
        (array 0xdf 0xbf 0 0 2 0x7ff)
        (array 0xe0 0xa0 0x80 0 3 0x800)
        (array 0xe0 0xbf 0xbf 0 3 0xfff)
        (array 0xe1 0x80 0x80 0 3 0x1000)
        (array 0xec 0xbf 0xbf 0 3 0xcfff)
        (array 0xed 0x80 0x80 0 3 0xd000)
        (array 0xed 0x9f 0xbf 0 3 0xd7ff)
        (array 0xee 0x80 0x80 0 3 0xe000)
        (array 0xef 0xbf 0xbf 0 3 0xffff)
        (array 0xf0 0x90 0x80 0x80 4 0x10000)
        (array 0xf0 0xbf 0xbf 0xbf 4 0x3ffff)
        (array 0xf1 0x80 0x80 0x80 4 0x40000)
        (array 0xf3 0xbf 0xbf 0xbf 4 0xfffff)
        (array 0xf4 0x80 0x80 0x80 4 0x100000)
        (array 0xf4 0x8f 0xbf 0xbf 4 0x10ffff))]
    [index : i64 0]
    (while (< index (array-length rows))
      (let
        [row : (& rows (Array i64 6)) (& (array-ref rows index))]
        [text : String
          (input-bytes
            (array-ref row 0)
            (array-ref row 1)
            (array-ref row 2)
            (array-ref row 3))]
        [end : i64 (+ 1 (array-ref row 4))]
        [view : (& text str) (string.substring-view (& text) 0 end)]
        (expect-scalar view 1 (array-ref row 5) end)
        (expect-valid view)
        (match (utf8.decode-at view end)
          [(End) unit]
          [_ (test.assert-true false "exact end")])
        (set! index (+ index 1))))))

(define (assert-all-leads) : unit
  (let
    [lead : i64 0]
    (while (< lead 256)
      (let
        [second : i64
          (if (= lead 0xe0)
            0xa0
            (if (= lead 0xf0)
              0x90
              0x80))]
        [text : String (input-bytes lead second 0x80 0x80)]
        (cond
          [(< lead 0x80) (expect-scalar (& text) 1 lead 2)]
          [(< lead 0xc0) (expect-error (& text) 2 1)]
          [(or (< lead 0xc2) (> lead 0xf4)) (expect-error (& text) 1 1)]
          [else
            (match (utf8.decode-at (& text) 1)
              [(Scalar scalar next)
                (test.assert-true
                  (<= scalar.value 0x10ffff)
                  "scalar upper bound")
                (test.assert-false
                  (and (>= scalar.value 0xd800) (<= scalar.value 0xdfff))
                  "no surrogate scalar")
                (test.assert-i64-eq
                  next
                  (if (< lead 0xe0)
                    3
                    (if (< lead 0xf0)
                      4
                      5))
                  "lead width")]
              [_ (test.assert-true false "valid leading byte")])])
        (set! lead (+ lead 1))))))

(define (assert-second-bytes) : unit
  (let
    [rows : (Array (Array i64 5) 9)
      (array
        (array 0xc2 2 0x80 0xbf 4)
        (array 0xdf 2 0x80 0xbf 4)
        (array 0xe0 3 0xa0 0xbf 5)
        (array 0xe1 3 0x80 0xbf 4)
        (array 0xed 3 0x80 0x9f 6)
        (array 0xef 3 0x80 0xbf 4)
        (array 0xf0 4 0x90 0xbf 5)
        (array 0xf1 4 0x80 0xbf 4)
        (array 0xf4 4 0x80 0x8f 7))]
    [index : i64 0]
    (while (< index (array-length rows))
      (let
        [row : (& rows (Array i64 5)) (& (array-ref rows index))]
        [byte : i64 0]
        (while (< byte 256)
          (let
            [text : String (input-bytes (array-ref row 0) byte 0x80 0x80)]
            [view : (& text str)
              (string.substring-view (& text) 0 (+ 1 (array-ref row 1)))]
            (cond
              [(or (< byte 0x80) (> byte 0xbf)) (expect-error view 4 2)]
              [(or (< byte (array-ref row 2)) (> byte (array-ref row 3)))
                (expect-error view (array-ref row 4) 2)
                ;; A conclusive range error wins over later truncation.
                (expect-error
                  (string.substring-view view 0 3)
                  (array-ref row 4)
                  2)]
              [else (expect-valid view)])
            (set! byte (+ byte 1))))
        (set! index (+ index 1))))))

(define (assert-truncation-and-continuations) : unit
  (let
    [width : i64 2]
    (while (<= width 4)
      (let
        [lead : i64
          (if (= width 2)
            0xc2
            (if (= width 3)
              0xe1
              0xf1))]
        [text : String (input-bytes lead 0x80 0x80 0x80)]
        [position : i64 1]
        (while (< position width)
          (expect-error
            (string.substring-view (& text) 0 (+ 1 position))
            3
            (+ 1 position))
          (let
            [byte : i64 0]
            (while (< byte 256)
              (let
                [broken : String
                  (input-bytes
                    lead
                    (if (= position 1)
                      byte
                      0x80)
                    (if (= position 2)
                      byte
                      0x80)
                    (if (= position 3)
                      byte
                      0x80))]
                [view : (& broken str)
                  (string.substring-view (& broken) 0 (+ 1 width))]
                (if (or (< byte 0x80) (> byte 0xbf))
                  (begin
                    (expect-error view 4 (+ 1 position))
                    (expect-error
                      (string.substring-view view 0 (+ 2 position))
                      4
                      (+ 1 position)))
                  (expect-valid view))
                (set! byte (+ byte 1)))))
          (set! position (+ position 1)))
        (set! width (+ width 1))))))

(define (assert-offsets-and-provenance) : unit
  (let
    [empty : String ""]
    [static : String "Aé€😀Z"]
    [copy : String (string.copy (& static))]
    [offsets : (Array i64 4)
      (array -9223372036854775808 -1 12 9223372036854775807)]
    [index : i64 0]
    (expect-valid (& empty))
    (match (utf8.decode-at (& empty) 0)
      [(End) unit]
      [_ (test.assert-true false "empty end")])
    (while (< index 4)
      (let
        [offset : i64 (array-ref offsets index)]
        (match (utf8.decode-at (& static) offset)
          [(Error error) (assert-error error 0 offset offset)]
          [_ (test.assert-true false "bad caller offset")])
        (set! index (+ index 1))))
    (expect-scalar (& static) 1 0xe9 3)
    (expect-scalar (& copy) 3 0x20ac 6)
    (expect-scalar (string.substring-view (& copy) 1 9) 5 0x1f600 9)
    (match (utf8.decode-at (& static) 2)
      [(Error error) (assert-error error 2 2 2)]
      [_ (test.assert-true false "interior continuation")])
    (expect-valid (& static))
    (expect-valid (& copy))
    (let
      [malformed : String (input-bytes 0xc2 65 0xff 0x80)]
      [saved : utf8.DecodeResult (utf8.decode-at (& malformed) 1)]
      (expect-error (& malformed) 4 2)
      (expect-scalar (& malformed) 2 65 3)
      (match saved
        [(Error error) (assert-error error 4 1 2)]
        [_ (test.assert-true false "retained decode result")])
      (test.assert-i64-eq
        (string.string-length (& malformed))
        5
        "arbitrary-byte conversion preserved"))
    (with-arena
      local
      (let
        [owned : String (string.copy (& static))]
        (expect-valid (& owned))))))

;; Independent scalar-to-UTF-8 construction exercises inverse decoding over
;; a deterministic sample spanning the complete scalar domain.
(define (assert-scalar-roundtrip) : unit
  (let
    [index : i64 0]
    (while (< index 4096)
      (let
        [value : i64 (% (* index 104729) 0x110000)]
        [width : i64
          (cond
            [(< value 0x80) 1]
            [(< value 0x800) 2]
            [(< value 0x10000) 3]
            [else 4])]
        [octets : (Array i64 4) (make-array i64 4)]
        [tail : i64 (- width 1)]
        [bits : i64 value]
        (while (> tail 0)
          (set! (array-ref octets tail) (+ 0x80 (% bits 64)))
          (set! bits (/ bits 64))
          (set! tail (- tail 1)))
        (set!
          (array-ref octets 0)
          (+
            bits
            (cond
              [(= width 1) 0]
              [(= width 2) 0xc0]
              [(= width 3) 0xe0]
              [else 0xf0])))
        (let
          [text : String
            (input-bytes
              (array-ref octets 0)
              (array-ref octets 1)
              (array-ref octets 2)
              (array-ref octets 3))]
          [view : (& text str) (string.substring-view (& text) 0 (+ width 1))]
          (if (and (>= value 0xd800) (<= value 0xdfff))
            (expect-error view 6 2)
            (begin
              (expect-scalar view 1 value (+ width 1))
              (expect-valid view)
              (let
                [out : byte_buf.ByteBuf (byte_buf.from-string "!!!!")]
                (match (utf8.encode
                  (utf8.UnicodeScalar (cast value : u32))
                  (byte_buf.as-mut-bytes (&mut out)))
                  [(Encoded actual-width)
                    (test.assert-i64-eq
                      actual-width
                      width
                      "property encoding width")
                    (let
                      [encoded : String (byte_buf.to-string out)]
                      (test.assert-string-eq
                        (string.substring-view (& encoded) 0 actual-width)
                        (string.substring-view view 1 width)
                        "encoding matches independent scalar byte construction"))]
                  [_ (test.assert-true false "valid scalar property encoding")])))))
        (set! index (+ index 1))))))

(define (assert-allocation-and-progress) : unit
  (let
    [text : String "Aé€😀Z"]
    [bad : String (input-bytes 0xf4 0x90 0x80 0x80)]
    [before : i64 (profile.alloc-total)]
    [round : i64 0]
    [count : i64 0]
    (while (< round 4096)
      (let
        [offset : i64 0]
        (while (< offset (string.string-length (& text)))
          (match (utf8.decode-at (& text) offset)
            [(Scalar _ next)
              (set! offset next)
              (set! count (+ count 1))]
            [_
              (test.assert-true false "walk must advance")
              (set! offset (string.string-length (& text)))]))
        (expect-valid (& text))
        (expect-error (& bad) 7 2)
        (set! round (+ round 1))))
    (test.assert-i64-eq
      (- (profile.alloc-total) before)
      0
      "decode and validation allocate nothing")
    (test.assert-i64-eq count (* 4096 5) "whole scalar walk count")))

(test utf8-boundaries (assert-boundaries))

(test utf8-leading-bytes (assert-all-leads))

(test utf8-second-bytes (assert-second-bytes))

(test utf8-truncation-and-continuations (assert-truncation-and-continuations))

(test utf8-offsets-and-provenance (assert-offsets-and-provenance))

(test utf8-scalar-roundtrip (assert-scalar-roundtrip))

(test utf8-allocation-and-progress (assert-allocation-and-progress))

(define (assert-item [result : utf8.IterNext] [expected : i64]) : unit
  (match result
    [(Item scalar)
      (test.assert-i64-eq (cast scalar.value : i64) expected "iterator scalar")]
    [_ (test.assert-true false "expected iterator item")]))

(define (assert-done [result : utf8.IterNext]) : unit
  (match result
    [(Done) unit]
    [_ (test.assert-true false "iterator must remain exhausted")]))

(define (assert-code-point-operations) : unit
  (let
    [buffer : byte_buf.ByteBuf (byte_buf.from-string "Aé€😀é")]
    [_nul : unit (set! buffer (byte_buf.push buffer (cast 0 : u8)))]
    [_last : unit (set! buffer (byte_buf.push buffer (cast 90 : u8)))]
    [text : String (byte_buf.to-string buffer)]
    [values : (Array i64 8) (array 65 233 0x20ac 0x1f600 101 0x301 0 90)]
    [offsets : (Array i64 9) (array 0 1 3 6 10 11 13 14 15)]
    [forward : (utf8.Iter text) (utf8.iterator (& text))]
    [reverse : (utf8.Iter text) (utf8.iterator (& text))]
    [mixed : (utf8.Iter text) (utf8.iterator (& text))]
    [index : i64 0]
    (match (utf8.count (& text))
      [(Count value)
        (test.assert-i64-eq
          value
          8
          "scalar count includes combining mark and NUL")]
      [_ (test.assert-true false "valid scalar count")])
    (while (< index 8)
      (assert-item (utf8.next (&mut forward)) (array-ref values index))
      (assert-item
        (utf8.next-back (&mut reverse))
        (array-ref values (- 7 index)))
      (match (utf8.decode-before (& text) (array-ref offsets (+ index 1)))
        [(Previous scalar start)
          (test.assert-i64-eq
            (cast scalar.value : i64)
            (array-ref values index)
            "reverse decode scalar")
          (test.assert-i64-eq
            start
            (array-ref offsets index)
            "reverse decode byte offset")]
        [_ (test.assert-true false "reverse decode succeeds")])
      (set! index (+ index 1)))
    (set! index 0)
    (while (< index 4)
      (assert-item (utf8.next (&mut mixed)) (array-ref values index))
      (assert-item (utf8.next-back (&mut mixed)) (array-ref values (- 7 index)))
      (set! index (+ index 1)))
    (assert-done (utf8.next (&mut forward)))
    (assert-done (utf8.next-back (&mut forward)))
    (assert-done (utf8.next-back (&mut reverse)))
    (assert-done (utf8.next (&mut reverse)))
    (assert-done (utf8.next (&mut mixed)))
    (assert-done (utf8.next-back (&mut mixed)))
    (set! index 0)
    (while (<= index 15)
      (let
        [expected : bool false]
        [point : i64 0]
        (while (< point 9)
          (when (= index (array-ref offsets point)) (set! expected true))
          (set! point (+ point 1)))
        (match (utf8.boundary-at (& text) index)
          [(Boundary actual)
            (test.assert-true (= actual expected) "byte boundary")]
          [_ (test.assert-true false "valid boundary query")]))
      (set! index (+ index 1)))
    (let
      [start : i64 0]
      (while (<= start 8)
        (let
          [end : i64 start]
          (while (<= end 8)
            (match (utf8.slice-range (& text) start end)
              [(Range first length)
                (test.assert-i64-eq
                  first
                  (array-ref offsets start)
                  "scalar byte range start")
                (test.assert-i64-eq
                  length
                  (- (array-ref offsets end) (array-ref offsets start))
                  "scalar byte range length")]
              [_ (test.assert-true false "valid scalar byte range")])
            (match (utf8.slice (& text) start end)
              [(Slice view)
                (test.assert-string-eq
                  view
                  (string.substring-view
                    (& text)
                    (array-ref offsets start)
                    (- (array-ref offsets end) (array-ref offsets start)))
                  "scalar slice equals exact byte view")]
              [_ (test.assert-true false "valid scalar slice")])
            (set! end (+ end 1))))
        (set! start (+ start 1))))))

(define (assert-checked-api-errors) : unit
  (let
    [bad : String (input-bytes 0xf4 0x90 0x80 0x80)]
    [forward : (utf8.Iter bad) (utf8.iterator (& bad))]
    [reverse : (utf8.Iter bad) (utf8.iterator (& bad))]
    (assert-item (utf8.next (&mut forward)) 65)
    (match (utf8.next (&mut forward))
      [(Invalid error) (assert-error error 7 1 2)]
      [_ (test.assert-true false "iteration reports invalid text")])
    (assert-done (utf8.next (&mut forward)))
    (match (utf8.next-back (&mut reverse))
      [(Invalid error) (assert-error error 7 1 2)]
      [_ (test.assert-true false "reverse iteration reports invalid text")])
    (assert-done (utf8.next-back (&mut reverse)))
    (match (utf8.count (& bad))
      [(CountError error) (assert-error error 7 1 2)]
      [_ (test.assert-true false "count rejects malformed input")])
    (match (utf8.boundary-at (& bad) 0)
      [(BoundaryError error) (assert-error error 7 1 2)]
      [_ (test.assert-true false "boundary validates whole input")])
    (match (utf8.slice (& bad) 0 0)
      [(SliceError error) (assert-error error 7 1 2)]
      [_ (test.assert-true false "even empty slice checks malformed suffix")])
    (let
      [offsets : (Array i64 3) (array -1 6 9223372036854775807)]
      [i : i64 0]
      (while (< i 3)
        (let
          [offset : i64 (array-ref offsets i)]
          (match (utf8.decode-before (& bad) offset)
            [(ReverseError error) (assert-error error 0 offset offset)]
            [_ (test.assert-true false "reverse caller offset")])
          (match (utf8.boundary-at (& bad) offset)
            [(BoundaryError error) (assert-error error 0 offset offset)]
            [_ (test.assert-true false "boundary caller offset")]))
        (set! i (+ i 1)))))
  (let
    [empty : String ""]
    [iter : (utf8.Iter empty) (utf8.iterator (& empty))]
    (assert-done (utf8.next-back (&mut iter)))
    (assert-done (utf8.next (&mut iter)))
    (match (utf8.decode-before (& empty) 0)
      [(Start) unit]
      [_ (test.assert-true false "empty reverse decode")])
    (let
      [ranges : (Array (Array i64 2) 3)
        (array (array -1 0) (array 1 0) (array 0 1))]
      [i : i64 0]
      (while (< i 3)
        (match (utf8.slice
          (& empty)
          (array-ref (array-ref ranges i) 0)
          (array-ref (array-ref ranges i) 1))
          [(InvalidRange) unit]
          [_ (test.assert-true false "invalid scalar range")])
        (set! i (+ i 1))))))

(define (assert-encoding) : unit
  (let
    [scalars : (Array i64 14)
      (array
        0
        0x7f
        0x80
        0x7ff
        0x800
        0xd7ff
        0xe000
        0xffff
        0x10000
        0x10ffff
        0xd800
        0xdfff
        0x110000
        0xffffffff)]
    [i : i64 0]
    (while (< i 14)
      (let
        [value : i64 (array-ref scalars i)]
        [output : byte_buf.ByteBuf (byte_buf.from-string "!!!!")]
        (match (utf8.encode
          (utf8.UnicodeScalar (cast value : u32))
          (byte_buf.as-mut-bytes (&mut output)))
          [(Encoded width)
            (test.assert-true (< i 10) "only valid scalar encodes")
            (let
              [text : String (byte_buf.to-string output)]
              (expect-scalar
                (string.substring-view (& text) 0 width)
                0
                value
                width)
              (let
                [tail : i64 width]
                (while (< tail 4)
                  (test.assert-i64-eq
                    (cast (string.string-ref (& text) tail) : i64)
                    33
                    "encoder leaves tail unchanged")
                  (set! tail (+ tail 1)))))]
          [(InvalidScalar actual)
            (test.assert-true (>= i 10) "invalid scalar rejected")
            (test.assert-i64-eq
              (cast actual : i64)
              value
              "invalid scalar retained")
            (let
              [text : String (byte_buf.to-string output)]
              (test.assert-string-eq
                (& text)
                "!!!!"
                "invalid scalar leaves output unchanged"))]
          [_ (test.assert-true false "four bytes always suffice")]))
      (set! i (+ i 1))))
  (let
    [output : byte_buf.ByteBuf (byte_buf.from-string "abc")]
    (match (utf8.encode
      (utf8.UnicodeScalar (cast 0x10000 : u32))
      (byte_buf.as-mut-bytes (&mut output)))
      [(InsufficientSpace required)
        (test.assert-i64-eq required 4 "encoder required capacity")]
      [_ (test.assert-true false "short output rejected")])
    (let
      [text : String (byte_buf.to-string output)]
      (test.assert-string-eq (& text) "abc" "short buffer unchanged"))))

(test utf8-code-point-operations (assert-code-point-operations))

(test utf8-checked-api-errors (assert-checked-api-errors))

(test utf8-encoding (assert-encoding))

(define (assert-code-point-allocation) : unit
  (let
    [text : String "Aé€😀"]
    [output : byte_buf.ByteBuf (byte_buf.from-string "!!!!")]
    [before : i64 (profile.alloc-total)]
    [round : i64 0]
    [total : i64 0]
    (while (< round 4096)
      (let
        [iter : (utf8.Iter text) (utf8.iterator (& text))]
        [done : bool false]
        (while (not done)
          (match (utf8.next (&mut iter))
            [(Item _) (set! total (+ total 1))]
            [(Done) (set! done true)]
            [_ (test.assert-true false "allocation walk")]))
        (let
          [reverse : (utf8.Iter text) (utf8.iterator (& text))]
          [finished : bool false]
          (while (not finished)
            (match (utf8.next-back (&mut reverse))
              [(Item _) (set! total (+ total 1))]
              [(Done) (set! finished true)]
              [_ (test.assert-true false "allocation reverse walk")])))
        (match (utf8.decode-before (& text) 10)
          [(Previous _ 6) (set! total (+ total 1))]
          [_ (test.assert-true false "allocation reverse decode")])
        (match (utf8.count (& text))
          [(Count n) (set! total (+ total n))]
          [_ (test.assert-true false "allocation count")])
        (match (utf8.slice-range (& text) 1 3)
          [(Range _ length) (set! total (+ total length))]
          [_ (test.assert-true false "allocation slice")])
        (match (utf8.boundary-at (& text) 3)
          [(Boundary true) (set! total (+ total 1))]
          [_ (test.assert-true false "allocation boundary")])
        (match (utf8.encode
          (utf8.UnicodeScalar (cast 0xfffd : u32))
          (byte_buf.as-mut-bytes (&mut output)))
          [(Encoded n) (set! total (+ total n))]
          [_ (test.assert-true false "allocation encoding")]))
      (set! round (+ round 1)))
    (test.assert-i64-eq
      (- (profile.alloc-total) before)
      0
      "code-point APIs allocate nothing")
    (test.assert-i64-eq total (* 4096 22) "code-point API work retained")))

(test utf8-code-point-allocation (assert-code-point-allocation))

(define (assert-reverse-prefix-cuts) : unit
  (let
    [text : String "Aé€😀Z"]
    [starts : (Array i64 12) (array 0 0 1 1 3 3 3 6 6 6 6 10)]
    [complete : (Array bool 12)
      (array true true false true false false true false false false true true)]
    [end : i64 0]
    (while (<= end 11)
      (match (utf8.decode-before (& text) end)
        [(Start) (test.assert-i64-eq end 0 "reverse start")]
        [(Previous _ start)
          (test.assert-true
            (array-ref complete end)
            "only complete prefix decodes")
          (test.assert-i64-eq
            start
            (array-ref starts end)
            "reverse complete prefix start")]
        [(ReverseError error)
          (test.assert-false
            (array-ref complete end)
            "only interior prefix truncates")
          (assert-error error 3 (array-ref starts end) end)])
      (set! end (+ end 1)))))

(test utf8-reverse-prefix-cuts (assert-reverse-prefix-cuts))

(define (assert-runtime-byte-semantics) : unit
  (let
    [text : String (format.format "{:.1}" "é")]
    [buffer : byte_buf.ByteBuf (byte_buf.from-string (string.copy (& text)))]
    [copied : String (byte_buf.to-string buffer)]
    [part : String (string.substring (& copied) 0 1)]
    (test.assert-i64-eq
      (string.string-length (& text))
      1
      "format precision counts bytes")
    (test.assert-i64-eq
      (cast (string.string-ref (& text) 0) : i64)
      0xc3
      "precision can produce malformed UTF-8")
    (test.assert-string-eq
      (& copied)
      (& text)
      "safe ByteBuf conversion preserves arbitrary bytes")
    (test.assert-string-eq
      (& part)
      (& text)
      "byte slicing preserves arbitrary bytes")
    (test.assert-i64-eq
      (string.index-of-byte (& copied) 0 (cast 0xc3 : u8))
      0
      "byte search ignores encoding")
    (test.assert-true
      (string.contains (& copied) (& part))
      "byte substring search ignores encoding")
    (match (utf8.validate (& text))
      [(Invalid error) (assert-error error 3 0 1)]
      [_
        (test.assert-true
          false
          "only explicit UTF-8 operation rejects runtime bytes")])))

(test utf8-runtime-byte-semantics (assert-runtime-byte-semantics))

(define (main) : i64
  (assert-boundaries)
  (assert-all-leads)
  (assert-second-bytes)
  (assert-truncation-and-continuations)
  (assert-offsets-and-provenance)
  (assert-scalar-roundtrip)
  (assert-allocation-and-progress)
  (assert-code-point-operations)
  (assert-checked-api-errors)
  (assert-encoding)
  (assert-code-point-allocation)
  (assert-reverse-prefix-cuts)
  (assert-runtime-byte-semantics)
  42)