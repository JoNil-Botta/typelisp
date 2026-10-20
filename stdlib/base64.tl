;# Strict bounded RFC 4648 standard-alphabet base64 over binary bytes.
;#
;# Encoding accepts any borrowed bytes and emits canonical terminal padding
;# with the standard `A-Z a-z 0-9 + /` alphabet. Decoding accepts only canonical
;# padded standard base64: the input length must be a multiple of four, `=` may
;# appear only in the final quantum in its exact legal count, unused pad bits
;# must be zero, and every other byte must be in the alphabet. Whitespace,
;# URL-safe `-`/`_`, interior or excess padding, nonzero pad bits, truncated
;# quanta, and trailing data are rejected with a stable source byte offset.
;#
;# `encoded-length` and `decoded-length` perform all checked arithmetic and,
;# for decoding, the complete validation pass before a destination is touched.
;# `encode-into` and `decode-into` write from offset zero of a caller-owned
;# `ByteBuf`: the backing capacity must cover the complete output and the
;# source may not overlap that backing storage. A failure leaves the
;# destination's live length and bytes unchanged. Callers that decode into
;# sensitive storage own wiping the physical prefix after the call.
;#
;# Envelope markers, line wrapping, and comment skipping belong to the
;# referring format, never to this codec. The convenience APIs return
;# `ByteBuf` values; no decoded or encoded bytes pass through a text `String`.
;#
;# Usage: `(import stdlib.base64)`.
;#
;# ```typelisp
;# (import stdlib.base64)
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (let
;#     [text : String "foobar"]
;#     (match
;#       (base64.encode (byte_buf.str-as-bytes (& text)))
;#       [(base64.Base64EncodeOk encoded)
;#         (match (base64.decode (byte_buf.as-bytes (& encoded)))
;#           [(base64.Base64DecodeOk decoded)
;#             (if (= (byte_buf.len decoded) 6) 42 1)]
;#           [(base64.Base64DecodeErr _) 1])]
;#       [(base64.Base64EncodeErr _) 1])))
;# ```
(import stdlib.byte_buf)
(import stdlib.string)
(import stdlib.test)

;: Stable strict base64 failure categories.
(defenum Base64ErrorKind
  (Base64InvalidLength)
  (Base64InvalidCharacter)
  (Base64InvalidPadding)
  (Base64NonZeroPadBits)
  (Base64LengthOverflow)
  (Base64DestinationTooSmall)
  (Base64DestinationOverlap))

;: Recoverable failure with a stable location.
;:
;: Source failures use `offset` as the byte offset of the first offending or
;: truncated input byte. Count overflow stores the rejected count and
;: `Base64DestinationTooSmall` stores the destination capacity;
;: `Base64DestinationOverlap` uses zero.
(defstruct Base64Error
  (kind Base64ErrorKind)
  (offset i64))

;: Result of a checked encoded/decoded length calculation.
(defenum Base64LengthResult
  (Base64LengthOk i64)
  (Base64LengthErr Base64Error))

;: Result of allocating a canonical encoded byte buffer.
(defenum Base64EncodeResult
  (Base64EncodeOk byte_buf.ByteBuf)
  (Base64EncodeErr Base64Error))

;: Result of encoding into caller-owned storage; the payload is bytes written.
(defenum Base64EncodeIntoResult
  (Base64EncodeIntoOk i64)
  (Base64EncodeIntoErr Base64Error))

;: Result of allocating a decoded byte buffer.
(defenum Base64DecodeResult
  (Base64DecodeOk byte_buf.ByteBuf)
  (Base64DecodeErr Base64Error))

;: Result of decoding into caller-owned storage; the payload is bytes written.
(defenum Base64DecodeIntoResult
  (Base64DecodeIntoOk i64)
  (Base64DecodeIntoErr Base64Error))

;: Return the 6-bit value of one standard-alphabet byte, or -1 when it is not
;: in `A-Z a-z 0-9 + /`.
(define (base64-value [byte : u8]) : i64
  (let
    [code : i64 (cast byte : i64)]
    (cond
      [(and (>= code 65) (<= code 90)) (- code 65)]
      [(and (>= code 97) (<= code 122)) (+ 26 (- code 97))]
      [(and (>= code 48) (<= code 57)) (+ 52 (- code 48))]
      [(= code 43) 62]
      [(= code 47) 63]
      [else -1])))

;: Return the standard-alphabet byte for a 6-bit value in `[0, 63]`.
(define (base64-char [value : i64]) : u8
  (cast
    (cond
      [(< value 26) (+ 65 value)]
      [(< value 52) (+ 97 (- value 26))]
      [(< value 62) (+ 48 (- value 52))]
      [(= value 62) 43]
      [else 47])
    : u8))

;: Return true when two half-open address ranges intersect.
(define (base64-ranges-overlap?
  [left-start : i64]
  [left-length : i64]
  [right-start : i64]
  [right-length : i64]) : bool
  (and
    (> left-length 0)
    (> right-length 0)
    (< left-start (+ right-start right-length))
    (< right-start (+ left-start left-length))))

;: Return true when `input` overlaps the complete backing storage of `dst`.
(define (base64-overlaps-destination?
  [input : (& input bytes)]
  [dst : (&mut dst byte_buf.ByteBuf)]) : bool
  (unsafe
    (let
      [source-start : i64 (cast (ptr->int (byte_buf.bytes-data input)) : i64)]
      [source-length : i64 (byte_buf.bytes-length input)]
      [destination-start : i64
        (cast
          (ptr->int (ptr-cast (__tl_array-data dst.slots) : (Ptr u8)))
          : i64)]
      [destination-length : i64 (byte_buf.capacity dst)]
      (base64-ranges-overlap?
        source-start
        source-length
        destination-start
        destination-length))))

;: Return the checked canonical encoded length for a raw byte count.
(define (encoded-length-count [input-length : i64]) : Base64LengthResult
  (if (< input-length 0)
    (Base64LengthErr (Base64Error (Base64InvalidLength) 0))
    (let
      [quanta : i64 (/ input-length 3)]
      [remainder : i64 (- input-length (* quanta 3))]
      (if (> quanta 2305843009213693951)
        (Base64LengthErr (Base64Error (Base64LengthOverflow) input-length))
        (let
          [base : i64 (* quanta 4)]
          (if (and (> remainder 0) (> base 9223372036854775803))
            (Base64LengthErr (Base64Error (Base64LengthOverflow) input-length))
            (Base64LengthOk
              (if (= remainder 0)
                base
                (+ base 4)))))))))

;: Return the checked canonical encoded length of borrowed bytes.
(define (encoded-length [input : (& input bytes)]) : Base64LengthResult
  (encoded-length-count (byte_buf.bytes-length input)))

;: Validate canonical padded standard base64 and return the decoded length.
;:
;: The complete input is checked before any caller-owned destination can be
;: mutated. Empty input is the canonical encoding of zero bytes. The result is
;: at most three quarters of the input length, so it cannot overflow once the
;: input length is representable.
(define (decoded-length [input : (& input bytes)]) : Base64LengthResult
  (let
    [n : i64 (byte_buf.bytes-length input)]
    [truncated : i64 (% n 4)]
    (if (!= truncated 0)
      (Base64LengthErr (Base64Error (Base64InvalidLength) (- n truncated)))
      (let
        [quanta : i64 (/ n 4)]
        [quantum : i64 0]
        [padding : i64 0]
        (begin
          (while (< quantum quanta)
            (let
              [base : i64 (* quantum 4)]
              [last : bool (= quantum (- quanta 1))]
              [b0 : u8 (byte_buf.bytes-ref input base)]
              [b1 : u8 (byte_buf.bytes-ref input (+ base 1))]
              [b2 : u8 (byte_buf.bytes-ref input (+ base 2))]
              [b3 : u8 (byte_buf.bytes-ref input (+ base 3))]
              [v0 : i64 (base64-value b0)]
              [v1 : i64 (base64-value b1)]
              [v2 : i64 (base64-value b2)]
              [v3 : i64 (base64-value b3)]
              (begin
                (if last
                  (begin
                    (when
                      (= (cast b0 : i64) 61)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidPadding) base))))
                    (when
                      (< v0 0)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidCharacter) base))))
                    (when
                      (= (cast b1 : i64) 61)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidPadding) (+ base 1)))))
                    (when
                      (< v1 0)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidCharacter) (+ base 1)))))
                    (if (= (cast b2 : i64) 61)
                      (begin
                        (when
                          (!= (cast b3 : i64) 61)
                          (return
                            (Base64LengthErr
                              (Base64Error (Base64InvalidPadding) (+ base 3)))))
                        (set! padding 2)
                        (when
                          (!= (bit-and v1 15) 0)
                          (return
                            (Base64LengthErr
                              (Base64Error (Base64NonZeroPadBits) (+ base 1))))))
                      (begin
                        (when
                          (< v2 0)
                          (return
                            (Base64LengthErr
                              (Base64Error (Base64InvalidCharacter) (+ base 2)))))
                        (if (= (cast b3 : i64) 61)
                          (begin
                            (set! padding 1)
                            (when
                              (!= (bit-and v2 3) 0)
                              (return
                                (Base64LengthErr
                                  (Base64Error
                                    (Base64NonZeroPadBits)
                                    (+ base 2))))))
                          (begin
                            (when
                              (< v3 0)
                              (return
                                (Base64LengthErr
                                  (Base64Error
                                    (Base64InvalidCharacter)
                                    (+ base 3)))))
                            (set! padding 0))))))
                  (begin
                    (when
                      (= (cast b0 : i64) 61)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidPadding) base))))
                    (when
                      (< v0 0)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidCharacter) base))))
                    (when
                      (= (cast b1 : i64) 61)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidPadding) (+ base 1)))))
                    (when
                      (< v1 0)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidCharacter) (+ base 1)))))
                    (when
                      (= (cast b2 : i64) 61)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidPadding) (+ base 2)))))
                    (when
                      (< v2 0)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidCharacter) (+ base 2)))))
                    (when
                      (= (cast b3 : i64) 61)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidPadding) (+ base 3)))))
                    (when
                      (< v3 0)
                      (return
                        (Base64LengthErr
                          (Base64Error (Base64InvalidCharacter) (+ base 3)))))))
                (set! quantum (+ quantum 1)))))
          (Base64LengthOk (- (* quanta 3) padding)))))))

;: Write the canonical encoding of validated-shape borrowed bytes from offset
;: zero of `dst`. The caller must have checked capacity and non-overlap.
(define (base64-encode-bytes!
  [input : (& input bytes)]
  [dst : (&mut dst byte_buf.ByteBuf)]) : unit
  (let
    [n : i64 (byte_buf.bytes-length input)]
    [quanta : i64 (/ n 3)]
    [remainder : i64 (- n (* quanta 3))]
    [quantum : i64 0]
    (begin
      (while (< quantum quanta)
        (let
          [offset : i64 (* quantum 3)]
          [out : i64 (* quantum 4)]
          [b0 : i64 (cast (byte_buf.bytes-ref input offset) : i64)]
          [b1 : i64 (cast (byte_buf.bytes-ref input (+ offset 1)) : i64)]
          [b2 : i64 (cast (byte_buf.bytes-ref input (+ offset 2)) : i64)]
          [word : i64 (bit-or (shl b0 16) (bit-or (shl b1 8) b2))]
          (begin
            (set!
              (array-ref dst.slots out)
              (base64-char (bit-and (shr word 18) 63)))
            (set!
              (array-ref dst.slots (+ out 1))
              (base64-char (bit-and (shr word 12) 63)))
            (set!
              (array-ref dst.slots (+ out 2))
              (base64-char (bit-and (shr word 6) 63)))
            (set!
              (array-ref dst.slots (+ out 3))
              (base64-char (bit-and word 63)))
            (set! quantum (+ quantum 1)))))
      (if (= remainder 1)
        (let
          [offset : i64 (* quanta 3)]
          [out : i64 (* quanta 4)]
          [b0 : i64 (cast (byte_buf.bytes-ref input offset) : i64)]
          (begin
            (set!
              (array-ref dst.slots out)
              (base64-char (bit-and (shr b0 2) 63)))
            (set!
              (array-ref dst.slots (+ out 1))
              (base64-char (bit-and (shl b0 4) 63)))
            (set! (array-ref dst.slots (+ out 2)) (cast 61 : u8))
            (set! (array-ref dst.slots (+ out 3)) (cast 61 : u8))))
        (if (= remainder 2)
          (let
            [offset : i64 (* quanta 3)]
            [out : i64 (* quanta 4)]
            [b0 : i64 (cast (byte_buf.bytes-ref input offset) : i64)]
            [b1 : i64 (cast (byte_buf.bytes-ref input (+ offset 1)) : i64)]
            [word : i64 (bit-or (shl b0 8) b1)]
            (begin
              (set!
                (array-ref dst.slots out)
                (base64-char (bit-and (shr word 10) 63)))
              (set!
                (array-ref dst.slots (+ out 1))
                (base64-char (bit-and (shr word 4) 63)))
              (set!
                (array-ref dst.slots (+ out 2))
                (base64-char (bit-and (shl word 2) 63)))
              (set! (array-ref dst.slots (+ out 3)) (cast 61 : u8))))
          unit)))))

;: Write canonical decoded bytes from validated borrowed base64 from offset
;: zero of `dst`. The caller must have checked capacity and non-overlap.
(define (base64-decode-bytes!
  [input : (& input bytes)]
  [dst : (&mut dst byte_buf.ByteBuf)]) : unit
  (let
    [n : i64 (byte_buf.bytes-length input)]
    [quanta : i64 (/ n 4)]
    [quantum : i64 0]
    (begin
      (while (< quantum quanta)
        (let
          [base : i64 (* quantum 4)]
          [out : i64 (* quantum 3)]
          [last : bool (= quantum (- quanta 1))]
          [d0 : i64 (base64-value (byte_buf.bytes-ref input base))]
          [d1 : i64 (base64-value (byte_buf.bytes-ref input (+ base 1)))]
          [d2 : i64 (base64-value (byte_buf.bytes-ref input (+ base 2)))]
          [d3 : i64 (base64-value (byte_buf.bytes-ref input (+ base 3)))]
          [count : i64
            (if last
              (if (< d2 0)
                1
                (if (< d3 0)
                  2
                  3))
              3)]
          (begin
            (set!
              (array-ref dst.slots out)
              (cast (bit-or (shl d0 2) (shr d1 4)) : u8))
            (when
              (>= count 2)
              (set!
                (array-ref dst.slots (+ out 1))
                (cast (bit-or (shl (bit-and d1 15) 4) (shr d2 2)) : u8)))
            (when
              (>= count 3)
              (set!
                (array-ref dst.slots (+ out 2))
                (cast (bit-or (shl (bit-and d2 3) 6) d3) : u8)))
            (set! quantum (+ quantum 1)))))
      unit)))

;: Allocate one canonical RFC 4648 encoding of borrowed bytes.
(define (encode [input : (& input bytes)]) : Base64EncodeResult
  (match (encoded-length input)
    [(Base64LengthErr error) (Base64EncodeErr error)]
    [(Base64LengthOk length)
      (let
        [out : byte_buf.ByteBuf (byte_buf.with-capacity length)]
        (begin
          (base64-encode-bytes! input (&mut out))
          (set! out.len length)
          (Base64EncodeOk out)))]))

;: Encode borrowed bytes into caller-owned storage from offset zero.
;:
;: The destination keeps its old live length and bytes on every failure.
(define (encode-into
  [input : (& input bytes)]
  [dst : (&mut dst byte_buf.ByteBuf)]) : Base64EncodeIntoResult
  (match (encoded-length input)
    [(Base64LengthErr error) (Base64EncodeIntoErr error)]
    [(Base64LengthOk length)
      (if (> length (byte_buf.capacity dst))
        (Base64EncodeIntoErr
          (Base64Error (Base64DestinationTooSmall) (byte_buf.capacity dst)))
        (if (and (> length 0) (base64-overlaps-destination? input dst))
          (Base64EncodeIntoErr (Base64Error (Base64DestinationOverlap) 0))
          (begin
            (base64-encode-bytes! input dst)
            (set! dst.len length)
            (Base64EncodeIntoOk length))))]))

;: Allocate one strict canonical decoding of borrowed base64 bytes.
(define (decode [input : (& input bytes)]) : Base64DecodeResult
  (match (decoded-length input)
    [(Base64LengthErr error) (Base64DecodeErr error)]
    [(Base64LengthOk length)
      (let
        [out : byte_buf.ByteBuf (byte_buf.with-capacity length)]
        (begin
          (base64-decode-bytes! input (&mut out))
          (set! out.len length)
          (Base64DecodeOk out)))]))

;: Decode borrowed canonical base64 bytes into caller-owned storage.
;:
;: Validation, capacity, and overlap checks complete before the first write.
;: The destination keeps its old live length and bytes on every failure.
(define (decode-into
  [input : (& input bytes)]
  [dst : (&mut dst byte_buf.ByteBuf)]) : Base64DecodeIntoResult
  (match (decoded-length input)
    [(Base64LengthErr error) (Base64DecodeIntoErr error)]
    [(Base64LengthOk length)
      (if (> length (byte_buf.capacity dst))
        (Base64DecodeIntoErr
          (Base64Error (Base64DestinationTooSmall) (byte_buf.capacity dst)))
        (if (and (> length 0) (base64-overlaps-destination? input dst))
          (Base64DecodeIntoErr (Base64Error (Base64DestinationOverlap) 0))
          (begin
            (base64-decode-bytes! input dst)
            (set! dst.len length)
            (Base64DecodeIntoOk length))))]))

(test
  base64-rfc4648-round-trip
  (let
    [text : String "foobar"]
    (match (encode (byte_buf.str-as-bytes (& text)))
      [(Base64EncodeErr _) (test.assert-true false "encode should succeed")]
      [(Base64EncodeOk encoded)
        (begin
          (test.assert-i64-eq (byte_buf.len encoded) 8 "encoded length")
          (match (decode (byte_buf.as-bytes (& encoded)))
            [(Base64DecodeErr _)
              (test.assert-true false "decode should succeed")]
            [(Base64DecodeOk decoded)
              (let
                [actual : String (byte_buf.to-string decoded)]
                (test.assert-string-eq
                  (& actual)
                  (& text)
                  "RFC 4648 vector round trip"))])
          (let
            [rendered : String (byte_buf.to-string encoded)]
            (test.assert-string-eq
              (& rendered)
              "Zm9vYmFy"
              "RFC 4648 vector spelling")))])))