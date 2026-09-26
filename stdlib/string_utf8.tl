;# Checked UTF-8 scalar decoding over borrowed byte strings.
;#
;# `decode-at` and `validate` allocate nothing and never replace invalid bytes.
;# They implement Unicode 17.0 section 3.9, Table 3-7 / RFC 3629. NUL,
;# noncharacters and unassigned scalar values are accepted; consumer policies
;# such as filename restrictions and normalization belong to the caller.
;#
;# ```typelisp
;# (import stdlib.string_utf8)
;# (define (main) : i64
;#   (let [text : String "A"]
;#     (match (string_utf8.decode-at (& text) 0)
;#       [(string_utf8.Scalar scalar next)
;#         (if (and (= scalar.value 65) (= next 1)) 42 1)]
;#       [_ 1])))
;# ```
(import stdlib.string)

;: A decoded Unicode scalar, distinct from the byte-sized `char` type.
;: Decoder-produced values are 0..0x10ffff excluding 0xd800..0xdfff.
;: Direct aggregate construction does not validate this invariant.
(defstruct UnicodeScalar
  (value u32))

;: Stable failure categories. C0/C1 and F5..FF are `InvalidLead`.
(defenum ErrorKind
  (InvalidOffset)
  (InvalidLead)
  (UnexpectedContinuation)
  (Truncated)
  (InvalidContinuation)
  (Overlong)
  (Surrogate)
  (OutOfRange))

;: Byte offsets in the original input. `failure-offset` identifies the first
;: byte proving invalidity, or input length for a missing byte. Invalid caller
;: offsets are preserved in both fields without reading the input.
(defstruct DecodeError
  (kind ErrorKind)
  (sequence-start i64)
  (failure-offset i64))

;: A scalar and strictly advancing next offset, exact end, or checked failure.
(defenum DecodeResult
  (:must-use)
  (Scalar UnicodeScalar i64)
  (End)
  (Error DecodeError))

;: Whole-input validation succeeds or returns the decoder's first error.
(defenum ValidationResult
  (:must-use)
  (Valid)
  (Invalid DecodeError))

;: Decode one scalar at `offset`. An interior continuation is an error;
;: preceding bytes are not rescanned. End is returned only at input length.
(define (decode-at [text : (& text str)] [offset : i64]) : DecodeResult
  (let
    [length : i64 (string.string-length text)]
    (begin
      (when
        (or (< offset 0) (> offset length))
        (return (Error (DecodeError (InvalidOffset) offset offset))))
      (when (= offset length) (return (End)))
      (let
        [lead : i64 (cast (string.string-ref text offset) : i64)]
        (begin
          (when
            (< lead 0x80)
            (return (Scalar (UnicodeScalar (cast lead : u32)) (+ offset 1))))
          (when
            (< lead 0xc0)
            (return
              (Error (DecodeError (UnexpectedContinuation) offset offset))))
          (when
            (or (< lead 0xc2) (> lead 0xf4))
            (return (Error (DecodeError (InvalidLead) offset offset))))
          (let
            [width : i64
              (if (< lead 0xe0)
                2
                (if (< lead 0xf0)
                  3
                  4))]
            [value : i64
              (bit-and
                lead
                (if (= width 2)
                  0x1f
                  (if (= width 3)
                    0x0f
                    7)))]
            [index : i64 1]
            ;; offset < length; compare against the remaining length before
            ;; addition or indexing. Even an i64-max offset cannot wrap.
            [remaining : i64 (- length offset)]
            (begin
              (while (< index width)
                (begin
                  (when
                    (>= index remaining)
                    (return (Error (DecodeError (Truncated) offset length))))
                  (let
                    [position : i64 (+ offset index)]
                    [byte : i64 (cast (string.string-ref text position) : i64)]
                    (begin
                      (when
                        (or (< byte 0x80) (> byte 0xbf))
                        (return
                          (Error
                            (DecodeError (InvalidContinuation) offset position))))
                      (if (= index 1)
                        (cond
                          [(or
                              (and (= lead 0xe0) (< byte 0xa0))
                              (and (= lead 0xf0) (< byte 0x90)))
                            (return
                              (Error (DecodeError (Overlong) offset position)))]
                          [(and (= lead 0xed) (>= byte 0xa0))
                            (return
                              (Error (DecodeError (Surrogate) offset position)))]
                          [(and (= lead 0xf4) (> byte 0x8f))
                            (return
                              (Error (DecodeError (OutOfRange) offset position)))]
                          [else unit])
                        unit)
                      ;; At most three six-bit additions after a three-bit
                      ;; lead; validated second-byte ranges bound the final
                      ;; value to a scalar <= 0x10ffff, far below i64 overflow.
                      (set! value (+ (* value 64) (- byte 0x80)))
                      (set! index (+ index 1))))))
              (Scalar (UnicodeScalar (cast value : u32)) (+ offset width)))))))))

;: Validate all input in linear time and constant auxiliary space.
(define (validate [text : (& text str)]) : ValidationResult
  (let
    [offset : i64 0]
    (begin
      (while true
        (match (decode-at text offset)
          [(Scalar _ next) (set! offset next)]
          [(End) (return (Valid))]
          [(Error error) (return (Invalid error))]))
      (Valid))))