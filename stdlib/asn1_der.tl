;# Bounded canonical ASN.1 DER primitives for certificate readers.
;#
;# `validate` checks exactly one value, without allocating, using a fixed
;# 64-frame stack. Limits bound source bytes, nesting and total TLVs. It checks
;# universal encodings used by X.509; schema readers additionally check tags,
;# required fields, DEFAULT omission and the contents of encapsulated values.
;# Errors contain only a category and a source byte offset. Ranges are offsets
;# into the original bytes, including headers when returned by `encoded`.
;#
;# ```typelisp
;# (import stdlib.asn1_der as der)
;# (import stdlib.byte_buf)
;# (define (main) : i64
;#   (let [null : byte_buf.ByteBuf (byte_buf.new)]
;#     (set! null (byte_buf.push null (cast 5 : u8)))
;#     (set! null (byte_buf.push null (cast 0 : u8)))
;#     (match (der.validate (byte_buf.as-bytes (& null)) (der.default-limits))
;#       [(der.Valid) 42]
;#       [(der.Invalid _) 1])))
;# ```
(import stdlib.byte_buf)
(import stdlib.x509_time as time)

;: Stable parser failure categories shared by certificate modules.
(defenum ErrorKind
  (InvalidLimit)
  (LimitExceeded)
  (Truncated)
  (InvalidTag)
  (InvalidLength)
  (InvalidValue)
  (TrailingData)
  (Duplicate)
  (AlgorithmMismatch)
  (InvalidTime)
  (InvalidEnvelope)
  (InvalidBase64)
  (UnsupportedGeneralName i64)
  (UnsupportedType i64))

;: First offending byte, or the first missing byte for truncation.
(defstruct Error
  (kind ErrorKind)
  (offset i64))

;: Copyable half-open source range. An absent optional range has length zero.
(defstruct Range
  (start i64)
  (length i64))

;: Source-byte, nesting (1..64) and node budgets, checked before traversal.
(defstruct Limits
  (max-bytes i64)
  (max-depth i64)
  (max-nodes i64))

;: Conservative defaults for one certificate or ASN.1 value.
(define (default-limits) : Limits
  (Limits 1048576 32 16384))

;: Validate caller-supplied budgets without arithmetic or allocation.
(define (limits-valid? [limits : Limits]) : bool
  (and
    (>= limits.max-bytes 0)
    (> limits.max-depth 0)
    (<= limits.max-depth 64)
    (> limits.max-nodes 0)))

;: Exact TLV location with identifier class (0..3), number and construction.
(defstruct Tlv
  (start i64)
  (content i64)
  (end i64)
  (tag-class i64)
  (tag i64)
  (constructed bool))

;: An empty sentinel used only after an internal sticky failure.
(define (empty-tlv) : Tlv
  (Tlv 0 0 0 0 0 false))

;: Complete encoded range of a TLV.
(define (encoded [value : Tlv]) : Range
  (Range value.start (- value.end value.start)))

;: Content range, excluding the identifier and length.
(define (contents [value : Tlv]) : Range
  (Range value.content (- value.end value.content)))

;: Internal sticky parser cursor; construct with `cursor`.
(defstruct Cursor
  (position i64)
  (end i64)
  (failed bool)
  (error Error)
  (nodes i64))

;: Construct a cursor; `read!` validates its range before accessing bytes.
(define (cursor [start : i64] [end : i64]) : Cursor
  (Cursor start end false (Error (InvalidValue) start) 0))

;: Retain the first failure without replacing its source location.
(define (fail! [state : (&mut state Cursor)] [kind : ErrorKind] [offset : i64]) : unit
  (when
    (not state.failed)
    (set! state.failed true)
    (set! state.error (Error kind offset))))

;: Read one bounded canonical TLV header; failure makes this cursor sticky.
;: Does not descend or interpret primitive contents. No allocation occurs.
(define (read! [input : (& input bytes)] [state : (&mut state Cursor)]) : Tlv
  (when state.failed (return (empty-tlv)))
  (when
    (or
      (< state.position 0)
      (< state.end state.position)
      (> state.end (byte_buf.bytes-length input)))
    (fail! state (InvalidLength) 0)
    (return (empty-tlv)))
  (let
    [start : i64 state.position]
    [position : i64 start]
    [identifier : i64 0]
    [tag : i64 0]
    [length : i64 0]
    (when
      (= position state.end)
      (fail! state (Truncated) position)
      (return (empty-tlv)))
    (set! identifier (cast (byte_buf.bytes-ref input position) : i64))
    (set! position (+ position 1))
    (set! tag (bit-and identifier 31))
    (when
      (= tag 31)
      (set! tag 0)
      (let
        [first : bool true]
        [more : bool true]
        (while more
          (when
            (= position state.end)
            (fail! state (Truncated) position)
            (return (empty-tlv)))
          (let
            [code : i64 (cast (byte_buf.bytes-ref input position) : i64)]
            (when
              (or
                (and first (= (bit-and code 127) 0))
                (> tag (/ (- 9223372036854775807 (bit-and code 127)) 128)))
              (fail! state (InvalidTag) position)
              (return (empty-tlv)))
            (set! tag (+ (* tag 128) (bit-and code 127)))
            (set! more (>= code 128))
            (set! first false)
            (set! position (+ position 1)))))
      (when (< tag 31) (fail! state (InvalidTag) start) (return (empty-tlv))))
    (when
      (= position state.end)
      (fail! state (Truncated) position)
      (return (empty-tlv)))
    (let
      [code : i64 (cast (byte_buf.bytes-ref input position) : i64)]
      (set! position (+ position 1))
      (if (< code 128)
        (set! length code)
        (let
          [count : i64 (- code 128)]
          [index : i64 0]
          (when
            (or (= count 0) (> count 8))
            (fail! state (InvalidLength) (- position 1))
            (return (empty-tlv)))
          (when
            (> count (- state.end position))
            (fail! state (Truncated) state.end)
            (return (empty-tlv)))
          (when
            (= (byte_buf.bytes-ref input position) (cast 0 : u8))
            (fail! state (InvalidLength) position)
            (return (empty-tlv)))
          (while (< index count)
            (let
              [next : i64 (cast (byte_buf.bytes-ref input position) : i64)]
              (when
                (> length (/ (- 9223372036854775807 next) 256))
                (fail! state (InvalidLength) position)
                (return (empty-tlv)))
              (set! length (+ (* length 256) next)))
            (set! position (+ position 1))
            (set! index (+ index 1)))
          (when
            (< length 128)
            (fail! state (InvalidLength) (- (- position count) 1))
            (return (empty-tlv))))))
    (when
      (> length (- state.end position))
      (fail! state (Truncated) state.end)
      (return (empty-tlv)))
    (set! state.position (+ position length))
    (Tlv
      start
      position
      state.position
      (shr identifier 6)
      tag
      (!= (bit-and identifier 32) 0))))

;: Read a field and enforce its complete identifier, including primitive form.
(define (expect!
  [input : (& input bytes)]
  [state : (&mut state Cursor)]
  [tag-class : i64]
  [tag : i64]
  [constructed : bool]) : Tlv
  (let
    [value : Tlv (read! input state)]
    (when
      (and
        (not state.failed)
        (or
          (!= value.tag-class tag-class)
          (!= value.tag tag)
          (!= value.constructed constructed)))
      (fail! state (InvalidTag) value.start))
    value))

;: Reject any remaining field after the expected schema was consumed.
(define (finish! [state : (&mut state Cursor)]) : unit
  (when
    (!= state.position state.end)
    (fail! state (TrailingData) state.position)))

;: Compare exact source ranges lexicographically without copying.
(define (compare-ranges
  [input : (& input bytes)]
  [left : Range]
  [right : Range]) : i64
  (let
    [index : i64 0]
    [count : i64
      (if (< left.length right.length)
        left.length
        right.length)]
    (while (< index count)
      (let
        [a : u8 (byte_buf.bytes-ref input (+ left.start index))]
        [b : u8 (byte_buf.bytes-ref input (+ right.start index))]
        (when (< a b) (return -1))
        (when (> a b) (return 1)))
      (set! index (+ index 1)))
    (cond
      [(< left.length right.length) -1]
      [(> left.length right.length) 1]
      [else 0])))

;: Validate a canonical signed INTEGER/ENUMERATED content range.
(define (integer!
  [input : (& input bytes)]
  [state : (&mut state Cursor)]
  [value : Tlv]) : unit
  (when (= value.content value.end) (fail! state (InvalidValue) value.content))
  (when
    (> (- value.end value.content) 1)
    (let
      [first : i64 (cast (byte_buf.bytes-ref input value.content) : i64)]
      [second : i64 (cast (byte_buf.bytes-ref input (+ value.content 1)) : i64)]
      (when
        (or
          (and (= first 0) (< second 128))
          (and (= first 255) (>= second 128)))
        (fail! state (InvalidValue) value.content)))))

;: Validate BIT STRING content, including an implicit context-specific field.
(define (bits!
  [input : (& input bytes)]
  [state : (&mut state Cursor)]
  [value : Tlv]) : unit
  (when
    (= value.content value.end)
    (fail! state (InvalidValue) value.content)
    (return unit))
  (let
    [unused : i64 (cast (byte_buf.bytes-ref input value.content) : i64)]
    (when
      (or (> unused 7) (and (= (- value.end value.content) 1) (!= unused 0)))
      (fail! state (InvalidValue) value.content)
      (return unit))
    (when
      (and
        (> unused 0)
        (!=
          (bit-and
            (cast (byte_buf.bytes-ref input (- value.end 1)) : i64)
            (- (shl 1 unused) 1))
          0))
      (fail! state (InvalidValue) (- value.end 1)))))

;: Validate minimally encoded, nonempty OID subidentifiers with checked i64 arcs.
(define (oid!
  [input : (& input bytes)]
  [state : (&mut state Cursor)]
  [value : Tlv]) : unit
  (let
    [position : i64 value.content]
    [arc : i64 0]
    [first : bool true]
    (when (= position value.end) (fail! state (InvalidValue) position))
    (while (< position value.end)
      (let
        [code : i64 (cast (byte_buf.bytes-ref input position) : i64)]
        (when
          (or
            (and first (= code 128))
            (> arc (/ (- 9223372036854775807 (bit-and code 127)) 128)))
          (fail! state (InvalidValue) position)
          (return unit))
        (set! arc (+ (* arc 128) (bit-and code 127)))
        (set! first (< code 128))
        (when first (set! arc 0))
        (set! position (+ position 1))))
    (when (not first) (fail! state (Truncated) position))))

;: Validate primitive encodings, including UTF-8 without a binary/String copy.
(define (primitive!
  [input : (& input bytes)]
  [state : (&mut state Cursor)]
  [value : Tlv]) : unit
  (when (!= value.tag-class 0) (return unit))
  (let
    [length : i64 (- value.end value.content)]
    [tag : i64 value.tag]
    (when
      (or
        (= tag 0)
        (= tag 15)
        (!= value.constructed (or (= tag 16) (= tag 17))))
      (fail! state (InvalidTag) value.start)
      (return unit))
    (when
      (not
        (or
          (and (>= tag 1) (<= tag 6))
          (= tag 10)
          (= tag 12)
          (= tag 13)
          (= tag 16)
          (= tag 17)
          (and (>= tag 18) (<= tag 28))
          (= tag 30)))
      (fail! state (UnsupportedType tag) value.start)
      (return unit))
    (cond
      [(= tag 1)
        (when
          (or
            (!= length 1)
            (and
              (!=
                (byte_buf.bytes-get input value.content (cast 0 : u8))
                (cast 0 : u8))
              (!=
                (byte_buf.bytes-get input value.content (cast 0 : u8))
                (cast 255 : u8))))
          (fail! state (InvalidValue) value.content))]
      [(or (= tag 2) (= tag 10)) (integer! input state value)]
      [(= tag 3) (bits! input state value)]
      [(= tag 5)
        (when (!= length 0) (fail! state (InvalidValue) value.content))]
      [(or (= tag 6) (= tag 13)) (oid! input state value)]
      [(or (= tag 18) (= tag 19) (= tag 22) (= tag 26))
        (let
          [position : i64 value.content]
          (while (< position value.end)
            (let
              [code : i64 (cast (byte_buf.bytes-ref input position) : i64)]
              (when
                (or
                  (> code 127)
                  (and
                    (= tag 18)
                    (not (or (= code 32) (and (>= code 48) (<= code 57)))))
                  (and (= tag 26) (or (< code 32) (> code 126)))
                  (and
                    (= tag 19)
                    (not
                      (or
                        (and (>= code 65) (<= code 90))
                        (and (>= code 97) (<= code 122))
                        (and (>= code 48) (<= code 57))
                        (= code 32)
                        (= code 39)
                        (and (>= code 40) (<= code 41))
                        (= code 43)
                        (= code 44)
                        (= code 45)
                        (= code 46)
                        (= code 47)
                        (= code 58)
                        (= code 61)
                        (= code 63)))))
                (fail! state (InvalidValue) position)))
            (set! position (+ position 1))))]
      [(or (= tag 23) (= tag 24))
        (match (time.parse
          (byte_buf.bytes-slice-view input value.content length)
          tag
          value.content)
          [(time.TimeOk _) unit]
          [(time.TimeErr error) (fail! state (InvalidTime) error.offset)])]
      [(or (= tag 28) (= tag 30))
        (let
          [width : i64
            (if (= tag 28)
              4
              2)]
          [position : i64 value.content]
          (when (!= (% length width) 0) (fail! state (InvalidValue) value.end))
          (while (and (not state.failed) (< position value.end))
            (let
              [scalar : i64 0]
              [index : i64 0]
              (while (< index width)
                (set!
                  scalar
                  (+
                    (* scalar 256)
                    (cast (byte_buf.bytes-ref input (+ position index)) : i64)))
                (set! index (+ index 1)))
              (when
                (or
                  (> scalar 1114111)
                  (and (>= scalar 55296) (<= scalar 57343)))
                (fail! state (InvalidValue) position)))
            (set! position (+ position width))))]
      [(= tag 12)
        (let
          [position : i64 value.content]
          (while (< position value.end)
            (let
              [lead : i64 (cast (byte_buf.bytes-ref input position) : i64)]
              [count : i64 0]
              [scalar : i64 0]
              [minimum : i64 0]
              (cond
                [(< lead 128) (set! scalar lead)]
                [(and (>= lead 194) (<= lead 223))
                  (set! count 1)
                  (set! scalar (- lead 192))
                  (set! minimum 128)]
                [(and (>= lead 224) (<= lead 239))
                  (set! count 2)
                  (set! scalar (- lead 224))
                  (set! minimum 2048)]
                [(and (>= lead 240) (<= lead 244))
                  (set! count 3)
                  (set! scalar (- lead 240))
                  (set! minimum 65536)]
                [else
                  (fail! state (InvalidValue) position)
                  (return unit)])
              (set! position (+ position 1))
              (while (> count 0)
                (when
                  (= position value.end)
                  (fail! state (Truncated) position)
                  (return unit))
                (let
                  [code : i64 (cast (byte_buf.bytes-ref input position) : i64)]
                  (when
                    (or (< code 128) (> code 191))
                    (fail! state (InvalidValue) position)
                    (return unit))
                  (set! scalar (+ (* scalar 64) (- code 128))))
                (set! position (+ position 1))
                (set! count (- count 1)))
              (when
                (or
                  (< scalar minimum)
                  (> scalar 1114111)
                  (and (>= scalar 55296) (<= scalar 57343)))
                (fail! state (InvalidValue) (- position 1))))))]
      [else unit])))

;: Result of an allocation-free full DER validation.
(defenum Validation
  (Valid)
  (Invalid Error))

;: Validate a bounded source range, charging one shared aggregate node budget.
;: `depth-offset` counts enclosing values for encapsulated DER. A cursor's
;: position is not changed; its first error and cumulative node count are kept.
(define (validate!
  [input : (& input bytes)]
  [range : Range]
  [limits : Limits]
  [depth-offset : i64]
  [work : (&mut work Cursor)]) : unit
  (when work.failed (return unit))
  (when
    (or (not (limits-valid? limits)) (< depth-offset 0) (< work.nodes 0))
    (fail! work (InvalidLimit) 0)
    (return unit))
  (when
    (or
      (< range.start 0)
      (< range.length 0)
      (> range.start (byte_buf.bytes-length input))
      (> range.length (- (byte_buf.bytes-length input) range.start)))
    (fail! work (InvalidLength) 0)
    (return unit))
  (let
    [end : i64 (+ range.start range.length)]
    [state : Cursor (cursor range.start end)]
    [ends : (Array i64 64) (make-array i64 64)]
    [sets : (Array bool 64) (make-array bool 64)]
    [previous-starts : (Array i64 64) (make-array i64 64)]
    [previous-ends : (Array i64 64) (make-array i64 64)]
    [depth : i64 0]
    [roots : i64 0]
    (when
      (> range.length limits.max-bytes)
      (fail! work (LimitExceeded) range.start)
      (return unit))
    (while (or (< state.position end) (> depth 0))
      (if (and (> depth 0) (= state.position (array-ref ends (- depth 1))))
        (set! depth (- depth 1))
        (begin
          (when
            (and (= depth 0) (> roots 0))
            (fail! work (TrailingData) state.position)
            (return unit))
          (when
            (or
              (>= work.nodes limits.max-nodes)
              (>= depth-offset limits.max-depth)
              (>= depth (- limits.max-depth depth-offset)))
            (fail! work (LimitExceeded) state.position)
            (return unit))
          (set!
            state.end
            (if (= depth 0)
              end
              (array-ref ends (- depth 1))))
          (let
            [value : Tlv (read! input (&mut state))]
            (when
              state.failed
              (fail! work state.error.kind state.error.offset)
              (return unit))
            (set! work.nodes (+ work.nodes 1))
            (when (= depth 0) (set! roots (+ roots 1)))
            (when
              (and (> depth 0) (array-ref sets (- depth 1)))
              (let
                [slot : i64 (- depth 1)]
                [previous : Range
                  (Range
                    (array-ref previous-starts slot)
                    (-
                      (array-ref previous-ends slot)
                      (array-ref previous-starts slot)))]
                (when
                  (and
                    (> previous.length 0)
                    (> (compare-ranges input previous (encoded value)) 0))
                  (fail! work (InvalidValue) value.start)
                  (return unit))
                (set! (array-ref previous-starts slot) value.start)
                (set! (array-ref previous-ends slot) value.end)))
            (primitive! input (&mut state) value)
            (when
              state.failed
              (fail! work state.error.kind state.error.offset)
              (return unit))
            (when
              value.constructed
              (set! (array-ref ends depth) value.end)
              (set!
                (array-ref sets depth)
                (and (= value.tag-class 0) (= value.tag 17)))
              (set! (array-ref previous-starts depth) 0)
              (set! (array-ref previous-ends depth) 0)
              (set! depth (+ depth 1))
              (set! state.position value.content))))))
    (when (!= roots 1) (fail! work (Truncated) range.start))))

;: Check one exact DER value, including SET order, without allocating.
(define (validate [input : (& input bytes)] [limits : Limits]) : Validation
  (let
    [work : Cursor (cursor 0 (byte_buf.bytes-length input))]
    (validate!
      input
      (Range 0 (byte_buf.bytes-length input))
      limits
      0
      (&mut work))
    (if work.failed
      (Invalid work.error)
      (Valid))))