;# Checked UTF-8 scalar decoding over borrowed byte strings.
;#
;# `decode-at` and `validate` allocate nothing and never replace invalid bytes.
;# They implement Unicode 17.0 section 3.9, Table 3-7 / RFC 3629. NUL,
;# noncharacters and unassigned scalar values are accepted; consumer policies
;# such as filename restrictions and normalization belong to the caller.
;# `decode-before` and double-ended `iterator`/`next`/`next-back` traverse scalars
;# without allocating views. An iterator reports an error once, then is exhausted;
;# reverse traversal can yield a valid suffix before encountering an earlier error.
;# `count`, `boundary-at`, and `slice-range` check the whole input in linear time.
;# `slice` borrows the selected bytes using the ordinary allocated view header;
;# `slice-range` instead returns a byte start/length without allocating. `encode`
;# writes into caller-provided mutable bytes, with no writes on either failure.
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
(import stdlib.byte_buf)

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
;: `InvalidLead` and `UnexpectedContinuation` use the current byte for both;
;: `Truncated` fails at input length and `InvalidContinuation` at the offending
;: byte; `Overlong` (E0/F0), `Surrogate` (ED) and `OutOfRange` (F4) point at the
;: second byte. Bytes are checked in order, so a conclusive earlier error wins
;: over later truncation.
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
  (decode-prefix-at text offset (string.string-length text)))

;; Shared bounded decoder for forward/reverse traversal without allocating
;; substring-view headers. Error offsets always refer to the original text.
(define (decode-prefix-at [text : (& text str)] [offset : i64] [length : i64]) : DecodeResult
  (let
    [full-length : i64 (string.string-length text)]
    (when
      (or (< length 0) (> length full-length))
      (return (Error (DecodeError (InvalidOffset) length length))))
    (when
      (or (< offset 0) (> offset length))
      (return (Error (DecodeError (InvalidOffset) offset offset))))
    (when (= offset length) (return (End)))
    (let
      [lead : i64 (cast (string.string-ref text offset) : i64)]
      (when
        (< lead 0x80)
        (return (Scalar (UnicodeScalar (cast lead : u32)) (+ offset 1))))
      (when
        (< lead 0xc0)
        (return (Error (DecodeError (UnexpectedContinuation) offset offset))))
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
        (while (< index width)
          (when
            (>= index remaining)
            (return (Error (DecodeError (Truncated) offset length))))
          (let
            [position : i64 (+ offset index)]
            [byte : i64 (cast (string.string-ref text position) : i64)]
            (when
              (or (< byte 0x80) (> byte 0xbf))
              (return
                (Error (DecodeError (InvalidContinuation) offset position))))
            (if (= index 1)
              (cond
                [(or
                    (and (= lead 0xe0) (< byte 0xa0))
                    (and (= lead 0xf0) (< byte 0x90)))
                  (return (Error (DecodeError (Overlong) offset position)))]
                [(and (= lead 0xed) (>= byte 0xa0))
                  (return (Error (DecodeError (Surrogate) offset position)))]
                [(and (= lead 0xf4) (> byte 0x8f))
                  (return (Error (DecodeError (OutOfRange) offset position)))]
                [else unit])
              unit)
            ;; At most three six-bit additions after a three-bit
            ;; lead; validated second-byte ranges bound the final
            ;; value to a scalar <= 0x10ffff, far below i64 overflow.
            (set! value (+ (* value 64) (- byte 0x80)))
            (set! index (+ index 1))))
        (Scalar (UnicodeScalar (cast value : u32)) (+ offset width))))))

;: Validate all input in linear time and constant auxiliary space.
(define (validate [text : (& text str)]) : ValidationResult
  (let
    [offset : i64 0]
    (while true
      (match (decode-at text offset)
        [(Scalar _ next) (set! offset next)]
        [(End) (return (Valid))]
        [(Error error) (return (Invalid error))]))
    (Valid)))

;: Stable spelling for diagnostics; offsets remain in `DecodeError`.
(define (error-kind-name [kind : ErrorKind]) : String
  (match kind
    [(InvalidOffset) "InvalidOffset"]
    [(InvalidLead) "InvalidLead"]
    [(UnexpectedContinuation) "UnexpectedContinuation"]
    [(Truncated) "Truncated"]
    [(InvalidContinuation) "InvalidContinuation"]
    [(Overlong) "Overlong"]
    [(Surrogate) "Surrogate"]
    [(OutOfRange) "OutOfRange"]))

;: Reverse decoding returns the previous scalar's starting byte offset.
(defenum ReverseResult
  (:must-use)
  (Previous UnicodeScalar i64)
  (Start)
  (ReverseError DecodeError))

;: Decode immediately before `end`, treating it as the input's exclusive end.
;: Only that suffix is checked; earlier invalid bytes are not skipped or repaired.
;: Error offsets refer to `text`, with truncation reported at `end`.
;: A full four-continuation window reports its final byte when its possible
;: lead lies outside the window, rather than blaming an earlier valid scalar.
(define (decode-before [text : (& text str)] [end : i64]) : ReverseResult
  (when
    (or (< end 0) (> end (string.string-length text)))
    (return (ReverseError (DecodeError (InvalidOffset) end end))))
  (when (= end 0) (return (Start)))
  (let
    [start : i64 (- end 1)]
    [width : i64 1]
    [search : bool true]
    (while search
      (let
        [byte : char (string.string-ref text start)]
        (if (and (>= byte (cast 0x80 : char)) (<= byte (cast 0xbf : char)))
          (if (and (> start 0) (< width 4))
            (begin
              (set! start (- start 1))
              (set! width (+ width 1)))
            (set! search false))
          (set! search false))))
    ;; Four continuations cannot end a valid scalar. The window can begin in
    ;; a preceding valid scalar, so its first byte is not a sound error site.
    (when
      (and
        (= width 4)
        (> start 0)
        (let
          [byte : char (string.string-ref text start)]
          (and (>= byte (cast 0x80 : char)) (<= byte (cast 0xbf : char)))))
      (return
        (ReverseError
          (DecodeError (UnexpectedContinuation) (- end 1) (- end 1)))))
    (match (decode-prefix-at text start end)
      [(Scalar scalar next)
        (if (= next end)
          (Previous scalar start)
          (ReverseError (DecodeError (UnexpectedContinuation) next next)))]
      [(Error error) (ReverseError error)]
      [(End) (Start)])))

;: Shared double-ended iterator. Errors are yielded once, then it is exhausted.
(defstruct Iter
  (:lifetimes source)
  (text (& source str))
  (front i64)
  (back i64)
  (exhausted bool))

(defenum IterNext
  (:must-use)
  (Item UnicodeScalar)
  (Done)
  (Invalid DecodeError))

;: Borrow bytes without validating or allocating a copy of their contents.
(define (iterator [text : (& source str)]) : (Iter source)
  (Iter text 0 (string.string-length text) false))

;: Advance by a complete scalar, or report the error once and become exhausted.
(define (next [iter : (&mut state (Iter source))]) : IterNext
  (when
    (or iter.exhausted (= iter.front iter.back))
    (set! iter.exhausted true)
    (return (Done)))
  (match (decode-prefix-at iter.text iter.front iter.back)
    [(Scalar scalar offset)
      (set! iter.front offset)
      (Item scalar)]
    [(End)
      (set! iter.exhausted true)
      (Done)]
    [(Error error)
      (set! iter.exhausted true)
      (Invalid error)]))

;: Advance from the other end. Mixing `next` and `next-back` never repeats a scalar.
(define (next-back [iter : (&mut state (Iter source))]) : IterNext
  (when
    (or iter.exhausted (= iter.front iter.back))
    (set! iter.exhausted true)
    (return (Done)))
  (match (decode-before iter.text iter.back)
    [(Previous scalar start)
      (set! iter.back start)
      (Item scalar)]
    [(Start)
      (set! iter.exhausted true)
      (Done)]
    [(ReverseError error)
      (set! iter.exhausted true)
      (Invalid error)]))

(defenum CountResult
  (:must-use)
  (Count i64)
  (CountError DecodeError))

;: Count Unicode scalars, including NUL and combining scalars individually.
(define (count [text : (& text str)]) : CountResult
  (let
    [offset : i64 0]
    [total : i64 0]
    (while true
      (match (decode-at text offset)
        [(Scalar _ next)
          (set! offset next)
          (set! total (+ total 1))]
        [(End) (return (Count total))]
        [(Error error) (return (CountError error))]))
    (Count total)))

(defenum BoundaryResult
  (:must-use)
  (Boundary bool)
  (BoundaryError DecodeError))

;: Check a byte offset after validating the complete input. Both ends are boundaries.
;: An invalid caller offset wins over malformed input; interior offsets return false.
(define (boundary-at [text : (& text str)] [offset : i64]) : BoundaryResult
  (let
    [length : i64 (string.string-length text)]
    (when
      (or (< offset 0) (> offset length))
      (return (BoundaryError (DecodeError (InvalidOffset) offset offset))))
    (match (validate text)
      [(Invalid error) (BoundaryError error)]
      [(Valid)
        (if (= offset length)
          (Boundary true)
          (let
            [byte : char (string.string-ref text offset)]
            (Boundary
              (or (< byte (cast 0x80 : char)) (> byte (cast 0xbf : char))))))])))

(defenum SliceResult
  (:lifetimes source)
  (:must-use)
  (Slice (& source str))
  (InvalidRange)
  (SliceError DecodeError))

(defenum SliceRangeResult
  (:must-use)
  (Range i64 i64)
  (InvalidRange)
  (RangeError DecodeError))

;: Resolve scalar-index range `[start, end)` into a byte start and byte length.
;: Negative/reversed ranges fail immediately; otherwise all input is validated,
;: including bytes outside the selected range. This operation allocates nothing.
(define (slice-range [text : (& text str)] [start : i64] [end : i64]) : SliceRangeResult
  (when (or (< start 0) (< end start)) (return (InvalidRange)))
  (let
    [offset : i64 0]
    [index : i64 0]
    [first : i64 -1]
    [last : i64 -1]
    (while true
      (when (= index start) (set! first offset))
      (when (= index end) (set! last offset))
      (match (decode-at text offset)
        [(Scalar _ next)
          (set! offset next)
          (set! index (+ index 1))]
        [(Error error) (return (RangeError error))]
        [(End)
          (if (or (< first 0) (< last 0))
            (return (InvalidRange))
            (return (Range first (- last first))))]))
    (InvalidRange)))

;: Borrow a checked scalar-index slice without copying bytes. Like
;: `string.substring-view`, this allocates a two-word view header in the
;: runtime's process-lifetime view arena. Use `slice-range` for allocation-free
;: traversal or range computation instead of repeatedly constructing views.
(define (slice [text : (& source str)] [start : i64] [end : i64]) : (SliceResult
    source)
  (match (slice-range text start end)
    [(Range first length) (Slice (string.substring-view text first length))]
    [(InvalidRange) (InvalidRange)]
    [(RangeError error) (SliceError error)]))

(defenum EncodeResult
  (:must-use)
  (Encoded i64)
  (InvalidScalar u32)
  (InsufficientSpace i64))

;: Write one shortest-form scalar into caller-provided bytes, without allocating.
;: Returns bytes written, the invalid scalar, or the required size. On either
;: error the output is untouched. Directly constructed UnicodeScalar values
;: are checked, including surrogates and values greater than U+10FFFF.
(define (encode [scalar : UnicodeScalar] [output : (&mut output bytes)]) : EncodeResult
  (let
    [value : i64 (cast scalar.value : i64)]
    (when
      (or (> value 0x10ffff) (and (>= value 0xd800) (<= value 0xdfff)))
      (return (InvalidScalar scalar.value)))
    (let
      [width : i64
        (cond
          [(< value 0x80) 1]
          [(< value 0x800) 2]
          [(< value 0x10000) 3]
          [else 4])]
      (when
        (< (byte_buf.bytes-mut-length output) width)
        (return (InsufficientSpace width)))
      (if (= width 1)
        (byte_buf.bytes-set! output 0 (cast value : u8))
        (begin
          (let
            [prefix : i64
              (cond [(= width 2) 0xc0] [(= width 3) 0xe0] [else 0xf0])]
            (byte_buf.bytes-set!
              output
              0
              (cast (+ (shr value (* (- width 1) 6)) prefix) : u8)))
          (let
            [index : i64 1]
            (while (< index width)
              (byte_buf.bytes-set!
                output
                index
                (cast
                  (+
                    (bit-and (shr value (* (- (- width index) 1) 6)) 0x3f)
                    0x80)
                  : u8))
              (set! index (+ index 1))))))
      (Encoded width))))