(import stdlib.byte_buf)
(import stdlib.profile)
(import stdlib.string)
(import stdlib.string_utf8 as utf8)
(import stdlib.test)

(define (input-bytes [a : i64] [b : i64] [c : i64] [d : i64]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "A")]
    (begin
      (set! buf (byte_buf.push buf (cast a : u8)))
      (set! buf (byte_buf.push buf (cast b : u8)))
      (set! buf (byte_buf.push buf (cast c : u8)))
      (set! buf (byte_buf.push buf (cast d : u8)))
      (byte_buf.to-string buf))))

(define (kind-code [kind : utf8.ErrorKind]) : i64
  (match kind
    [(utf8.InvalidOffset) 0]
    [(utf8.InvalidLead) 1]
    [(utf8.UnexpectedContinuation) 2]
    [(utf8.Truncated) 3]
    [(utf8.InvalidContinuation) 4]
    [(utf8.Overlong) 5]
    [(utf8.Surrogate) 6]
    [(utf8.OutOfRange) 7]))

(define (assert-error
  [error : utf8.DecodeError]
  [kind : i64]
  [start : i64]
  [failure : i64]) : unit
  (begin
    (test.assert-i64-eq (kind-code error.kind) kind "UTF-8 error kind")
    (test.assert-i64-eq error.sequence-start start "UTF-8 sequence start")
    (test.assert-i64-eq error.failure-offset failure "UTF-8 failure offset")))

(define (expect-error [input : (& input str)] [kind : i64] [failure : i64]) : unit
  (begin
    (match (utf8.decode-at input 1)
      [(utf8.Error error) (assert-error error kind 1 failure)]
      [_ (test.assert-true false "decode must reject")])
    (match (utf8.validate input)
      [(utf8.Invalid error) (assert-error error kind 1 failure)]
      [_ (test.assert-true false "validator must return the same first error")])))

(define (expect-scalar
  [input : (& input str)]
  [offset : i64]
  [value : i64]
  [next : i64]) : unit
  (match (utf8.decode-at input offset)
    [(utf8.Scalar scalar actual-next)
      (begin
        (test.assert-i64-eq (cast scalar.value : i64) value "scalar value")
        (test.assert-i64-eq actual-next next "next byte offset")
        (test.assert-true (> actual-next offset) "strict forward progress"))]
    [_ (test.assert-true false "expected decoded scalar")]))

(define (expect-valid [input : (& input str)]) : unit
  (match (utf8.validate input)
    [(utf8.Valid) unit]
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
        (begin
          (expect-scalar view 1 (array-ref row 5) end)
          (expect-valid view)
          (match (utf8.decode-at view end)
            [(utf8.End) unit]
            [_ (test.assert-true false "exact end")])
          (set! index (+ index 1)))))))

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
        (begin
          (cond
            [(< lead 0x80) (expect-scalar (& text) 1 lead 2)]
            [(< lead 0xc0) (expect-error (& text) 2 1)]
            [(or (< lead 0xc2) (> lead 0xf4)) (expect-error (& text) 1 1)]
            [else
              (match (utf8.decode-at (& text) 1)
                [(utf8.Scalar scalar next)
                  (begin
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
                      "lead width"))]
                [_ (test.assert-true false "valid leading byte")])])
          (set! lead (+ lead 1)))))))

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
        (begin
          (while (< byte 256)
            (let
              [text : String (input-bytes (array-ref row 0) byte 0x80 0x80)]
              [view : (& text str)
                (string.substring-view (& text) 0 (+ 1 (array-ref row 1)))]
              (begin
                (cond
                  [(or (< byte 0x80) (> byte 0xbf)) (expect-error view 4 2)]
                  [(or (< byte (array-ref row 2)) (> byte (array-ref row 3)))
                    (begin
                      (expect-error view (array-ref row 4) 2)
                      ;; A conclusive range error wins over later truncation.
                      (expect-error
                        (string.substring-view view 0 3)
                        (array-ref row 4)
                        2))]
                  [else (expect-valid view)])
                (set! byte (+ byte 1)))))
          (set! index (+ index 1)))))))

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
        (begin
          (while (< position width)
            (begin
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
                    (begin
                      (if (or (< byte 0x80) (> byte 0xbf))
                        (begin
                          (expect-error view 4 (+ 1 position))
                          (expect-error
                            (string.substring-view view 0 (+ 2 position))
                            4
                            (+ 1 position)))
                        (expect-valid view))
                      (set! byte (+ byte 1))))))
              (set! position (+ position 1))))
          (set! width (+ width 1)))))))

(define (assert-offsets-and-provenance) : unit
  (let
    [empty : String ""]
    [static : String "Aé€😀Z"]
    [copy : String (string.copy (& static))]
    [offsets : (Array i64 4)
      (array -9223372036854775808 -1 12 9223372036854775807)]
    [index : i64 0]
    (begin
      (expect-valid (& empty))
      (match (utf8.decode-at (& empty) 0)
        [(utf8.End) unit]
        [_ (test.assert-true false "empty end")])
      (while (< index 4)
        (let
          [offset : i64 (array-ref offsets index)]
          (begin
            (match (utf8.decode-at (& static) offset)
              [(utf8.Error error) (assert-error error 0 offset offset)]
              [_ (test.assert-true false "bad caller offset")])
            (set! index (+ index 1)))))
      (expect-scalar (& static) 1 0xe9 3)
      (expect-scalar (& copy) 3 0x20ac 6)
      (expect-scalar (string.substring-view (& copy) 1 9) 5 0x1f600 9)
      (match (utf8.decode-at (& static) 2)
        [(utf8.Error error) (assert-error error 2 2 2)]
        [_ (test.assert-true false "interior continuation")])
      (expect-valid (& static))
      (expect-valid (& copy))
      (let
        [malformed : String (input-bytes 0xc2 65 0xff 0x80)]
        [saved : utf8.DecodeResult (utf8.decode-at (& malformed) 1)]
        (begin
          (expect-error (& malformed) 4 2)
          (expect-scalar (& malformed) 2 65 3)
          (match saved
            [(utf8.Error error) (assert-error error 4 1 2)]
            [_ (test.assert-true false "retained decode result")])
          (test.assert-i64-eq
            (string.string-length (& malformed))
            5
            "arbitrary-byte conversion preserved")))
      (with-arena
        local
        (let
          [owned : String (string.copy (& static))]
          (expect-valid (& owned)))))))

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
        (begin
          (while (> tail 0)
            (begin
              (set! (array-ref octets tail) (+ 0x80 (% bits 64)))
              (set! bits (/ bits 64))
              (set! tail (- tail 1))))
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
                (expect-valid view))))
          (set! index (+ index 1)))))))

(define (assert-allocation-and-progress) : unit
  (let
    [text : String "Aé€😀Z"]
    [bad : String (input-bytes 0xf4 0x90 0x80 0x80)]
    [before : i64 (profile.alloc-total)]
    [round : i64 0]
    [count : i64 0]
    (begin
      (while (< round 4096)
        (let
          [offset : i64 0]
          (begin
            (while (< offset (string.string-length (& text)))
              (match (utf8.decode-at (& text) offset)
                [(utf8.Scalar _ next)
                  (begin
                    (set! offset next)
                    (set! count (+ count 1)))]
                [_
                  (begin
                    (test.assert-true false "walk must advance")
                    (set! offset (string.string-length (& text))))]))
            (expect-valid (& text))
            (expect-error (& bad) 7 2)
            (set! round (+ round 1)))))
      (test.assert-i64-eq
        (- (profile.alloc-total) before)
        0
        "decode and validation allocate nothing")
      (test.assert-i64-eq count (* 4096 5) "whole scalar walk count"))))

(test utf8-boundaries (assert-boundaries))

(test utf8-leading-bytes (assert-all-leads))

(test utf8-second-bytes (assert-second-bytes))

(test utf8-truncation-and-continuations (assert-truncation-and-continuations))

(test utf8-offsets-and-provenance (assert-offsets-and-provenance))

(test utf8-scalar-roundtrip (assert-scalar-roundtrip))

(test utf8-allocation-and-progress (assert-allocation-and-progress))

(define (main) : i64
  (begin
    (assert-boundaries)
    (assert-all-leads)
    (assert-second-bytes)
    (assert-truncation-and-continuations)
    (assert-offsets-and-provenance)
    (assert-scalar-roundtrip)
    (assert-allocation-and-progress)
    42))