;# Bounded incremental raw DEFLATE decoding (RFC 1951).
;#
;# `decoder-new` validates caller limits before initializing fixed workspace
;# and allocating a bounded history ring. `step!` borrows input/output for the
;# call, reports exact consumed/produced counts, and never allocates. `decode`
;# is a bounded convenience loop over that engine. No zlib framing is implied.
;#
;# Usage: `(import stdlib.compress.deflate)`. Create bounded defaults with
;# `default-limits`, pass `(& limits)` to `decoder-new` or `decode`, and handle
;# the typed result. `DeflateDecoded.consumed` preserves a container suffix.
;# See `docs/deflate.md` and `examples/deflate_decode.tl` for complete examples.
(import stdlib.byte_buf)
(import stdlib.iterator)

;: Stable decoding and resource failure categories.
(defenum DeflateErrorKind
  (InvalidLimits)
  (InvalidState)
  (MalformedBlock)
  (MalformedTree)
  (InvalidCode)
  (Truncated)
  (ReservedEncoding)
  (InvalidDistance)
  (Overflow)
  (InputLimit)
  (OutputLimit)
  (WindowLimit)
  (WorkLimit)
  (RatioLimit))

;: A failure at cumulative accepted-input and emitted-output byte counts.
(defstruct DeflateError
  (kind DeflateErrorKind)
  (input i64)
  (output i64))

;: Cumulative limits. Ratio zero permits only `startup-bytes` output.
(defstruct DeflateLimits
  (max-input i64)
  (max-output i64)
  (window-bytes i64)
  (max-work i64)
  (ratio i64)
  (startup-bytes i64))

;: Conservative defaults: 64 MiB input, 256 MiB output, full history.
(define (default-limits) : DeflateLimits
  (DeflateLimits 67108864 268435456 32768 2147483647 1024 1024))

;: Whether all limit fields are representable nonnegative bounds.
(define (limits-valid? [limits : (& limits DeflateLimits)]) : bool
  (and
    (>= limits.max-input 0)
    (>= limits.max-output 0)
    (>= limits.window-bytes 0)
    (<= limits.window-bytes 32768)
    (>= limits.max-work 0)
    (>= limits.ratio 0)
    (>= limits.startup-bytes 0)))

;: Owning resumable state. Public fields are checked; do not mutate them.
;: Phases 0..16 are active, 17 is Done, and 18 is a sticky failure.
(defstruct Decoder
  (limits DeflateLimits)
  (phase i64)
  (final bool)
  (bits i64)
  (bit-count i64)
  (field-value i64)
  (field-read i64)
  (symbol-code i64)
  (symbol-length i64)
  (symbol-first i64)
  (symbol-index i64)
  (literal-count i64)
  (distance-count i64)
  (code-count i64)
  (length-index i64)
  (repeat-value i64)
  (repeat-base i64)
  (repeat-extra i64)
  (pending-value i64)
  (pending-length i64)
  (pending-distance i64)
  (after-literal i64)
  (stored-left i64)
  (total-input i64)
  (total-output i64)
  (work i64)
  (history-position i64)
  (history byte_buf.ByteBuf)
  (lengths (Array i64 318))
  (offsets (Array i64 16))
  (tree-counts (Array i64 48))
  (tree-symbols (Array i64 339))
  (failure DeflateError))

;: Construction result, including invalid limits or insufficient initial work.
(defenum DeflateNewResult
  (DeflateNewOk Decoder)
  (DeflateNewErr DeflateError))

;: Outcome of an incremental call. A terminal outcome is repeated unchanged.
(defenum DeflateStatus
  (NeedInput)
  (NeedOutput)
  (Done)
  (Error DeflateError))

;: Per-call counts, including partial progress before an error.
(defstruct DeflateStep
  (consumed i64)
  (produced i64)
  (status DeflateStatus))

;: An owned result and the length of its compressed member, excluding suffixes.
(defstruct DeflateDecoded
  (bytes byte_buf.ByteBuf)
  (consumed i64))

;: One-shot decoding result.
(defenum DeflateDecodeResult
  (DeflateDecodeOk DeflateDecoded)
  (DeflateDecodeErr DeflateError))

;: Per-call positions. No chunk or raw pointer is stored here.
(defstruct DeflateCursor
  (input i64)
  (output i64))

;: Construct fixed workspace after validating limits and its initial work cost.
;: Initial work is 721 integer workspace cells plus the history byte capacity.
(define (decoder-new [limits : (& limits DeflateLimits)]) : DeflateNewResult
  (cond
    [(not (limits-valid? limits))
      (DeflateNewErr (DeflateError (InvalidLimits) 0 0))]
    [(< limits.max-work (+ 721 limits.window-bytes))
      (DeflateNewErr (DeflateError (WorkLimit) 0 0))]
    [else
      (let
        [window : i64 limits.window-bytes]
        (DeflateNewOk
          (Decoder
            (DeflateLimits
              limits.max-input
              limits.max-output
              limits.window-bytes
              limits.max-work
              limits.ratio
              limits.startup-bytes)
            0
            false
            0
            0
            0
            0
            0
            1
            0
            0
            257
            1
            4
            0
            0
            0
            0
            0
            0
            0
            11
            0
            0
            0
            (+ 721 window)
            0
            (byte_buf.from-array (__tl_make-array u8 window))
            (make-array i64 318)
            (make-array i64 16)
            (make-array i64 48)
            (make-array i64 339)
            (DeflateError (InvalidState) 0 0))))]))

;: Copy a failure without retaining any caller storage.
(define (deflate-error-copy [error : (& error DeflateError)]) : DeflateError
  (DeflateError (clone error.kind) error.input error.output))

;: Enter the sticky failed phase.
(define (deflate-fail! [state : (&mut state Decoder)] [kind : DeflateErrorKind]) : unit
  (set! state.phase 18)
  (set! state.failure (DeflateError kind state.total-input state.total-output)))

;: Check public state shapes and bounded scalar ranges before an active call.
(define (deflate-state-valid? [state : (& state Decoder)]) : bool
  (and
    (limits-valid? (& state.limits))
    (>= state.phase 0)
    (<= state.phase 18)
    (>= state.bits 0)
    (<= state.bits 255)
    (>= state.bit-count 0)
    (<= state.bit-count 8)
    (< state.bits (shl 1 state.bit-count))
    (>= state.field-read 0)
    (<= state.field-read 16)
    (>= state.field-value 0)
    (< state.field-value (shl 1 state.field-read))
    (>= state.symbol-length 1)
    (<= state.symbol-length 16)
    (>= state.symbol-code 0)
    (<= state.symbol-code 65535)
    (>= state.symbol-first 0)
    (<= state.symbol-first 65536)
    (>= state.symbol-index 0)
    (<= state.symbol-index 288)
    (>= state.literal-count 257)
    (<= state.literal-count 286)
    (>= state.distance-count 1)
    (<= state.distance-count 32)
    (>= state.code-count 4)
    (<= state.code-count 19)
    (>= state.length-index 0)
    (<= state.length-index 318)
    (>= state.repeat-value 0)
    (<= state.repeat-value 15)
    (>= state.repeat-base 0)
    (<= state.repeat-base 138)
    (>= state.repeat-extra 0)
    (<= state.repeat-extra 13)
    (>= state.pending-value 0)
    (<= state.pending-value 258)
    (>= state.pending-length 0)
    (<= state.pending-length 258)
    (>= state.pending-distance 0)
    (<= state.pending-distance 32768)
    (or (= state.after-literal 4) (= state.after-literal 11))
    (>= state.stored-left 0)
    (<= state.stored-left 65535)
    (>= state.total-input 0)
    (<= state.total-input state.limits.max-input)
    (>= state.total-output 0)
    (<= state.total-output state.limits.max-output)
    (>= state.work 0)
    (<= state.work state.limits.max-work)
    (= (byte_buf.capacity (& state.history)) state.limits.window-bytes)
    (>= state.history-position 0)
    (if (= state.limits.window-bytes 0)
      (= state.history-position 0)
      (< state.history-position state.limits.window-bytes))
    (= (array-length state.lengths) 318)
    (= (array-length state.offsets) 16)
    (= state.history.len state.limits.window-bytes)
    (or (!= state.phase 8) (<= state.length-index state.code-count))
    (or
      (and (!= state.phase 9) (!= state.phase 10))
      (<= state.length-index (+ state.literal-count state.distance-count)))
    (or (!= state.phase 15) (<= state.pending-value 255))
    (or
      (and
        (!= state.phase 12)
        (!= state.phase 13)
        (!= state.phase 14)
        (!= state.phase 16))
      (and (>= state.pending-length 3) (<= state.pending-length 258))
      (and (= state.phase 16) (> state.pending-length 0)))
    (or
      (!= state.phase 16)
      (and
        (> state.pending-distance 0)
        (<= state.pending-distance state.total-output)
        (<= state.pending-distance state.limits.window-bytes)))))

;: Charge deterministic semantic work with subtraction-based overflow checks.
(define (deflate-charge! [state : (&mut state Decoder)] [units : i64]) : bool
  (cond
    [(or (< units 0) (< state.work 0) (> state.work state.limits.max-work))
      (deflate-fail! state (InvalidState))
      false]
    [(> units (- 9223372036854775807 state.work))
      (deflate-fail! state (Overflow))
      false]
    [(> units (- state.limits.max-work state.work))
      (deflate-fail! state (WorkLimit))
      false]
    [else
      (set! state.work (+ state.work units))
      true]))

;: Read one necessary bit, returning -1 for suspension or a sticky error.
(define (deflate-bit!
  [state : (&mut state Decoder)]
  [input : (& input bytes)]
  [cursor : (&mut cursor DeflateCursor)]) : i64
  (when
    (or
      (< cursor.input 0)
      (> cursor.input (byte_buf.bytes-length input))
      (< state.bit-count 0)
      (> state.bit-count 8)
      (< state.bits 0)
      (>= state.bits (shl 1 state.bit-count))
      (< state.total-input 0)
      (> state.total-input state.limits.max-input))
    (deflate-fail! state (InvalidState))
    (return -1))
  (when
    (= state.bit-count 0)
    (when (= cursor.input (byte_buf.bytes-length input)) (return -1))
    (when
      (= state.total-input 9223372036854775807)
      (deflate-fail! state (Overflow))
      (return -1))
    (when
      (= state.total-input state.limits.max-input)
      (deflate-fail! state (InputLimit))
      (return -1))
    (unless (deflate-charge! state 1) (return -1))
    (set! state.bits (cast (byte_buf.bytes-ref input cursor.input) : i64))
    (set! state.bit-count 8)
    (set! cursor.input (+ cursor.input 1))
    (set! state.total-input (+ state.total-input 1)))
  (unless (deflate-charge! state 1) (return -1))
  (let
    [bit : i64 (bit-and state.bits 1)]
    (set! state.bits (shr state.bits 1))
    (set! state.bit-count (- state.bit-count 1))
    bit))

;: Resume a little-endian scalar field of at most 16 bits.
(define (deflate-field!
  [state : (&mut state Decoder)]
  [input : (& input bytes)]
  [cursor : (&mut cursor DeflateCursor)]
  [width : i64]) : i64
  (when
    (or
      (< width 0)
      (> width 16)
      (< state.field-read 0)
      (> state.field-read width)
      (< state.field-value 0)
      (>= state.field-value (shl 1 state.field-read)))
    (deflate-fail! state (InvalidState))
    (return -1))
  (while (< state.field-read width)
    (let
      [bit : i64 (deflate-bit! state input cursor)]
      (when (< bit 0) (return -1))
      (set!
        state.field-value
        (bit-or state.field-value (shl bit state.field-read)))
      (set! state.field-read (+ state.field-read 1))))
  (let
    [value : i64 state.field-value]
    (set! state.field-read 0)
    (set! state.field-value 0)
    value))

;: Build a canonical table; each count segment stores its maximum length at
;: index zero. Mode 0 requires completeness, 1 allows a single
;: one-bit symbol, and 2 also permits the empty distance alphabet.
;: Every array and index is checked even for a direct call with forged data.
(define (deflate-build-tree!
  [counts : (&mut counts (Array i64 48))]
  [symbols : (&mut symbols (Array i64 339))]
  [lengths : (& lengths (Array i64 318))]
  [start : i64]
  [count : i64]
  [alphabet : i64]
  [mode : i64]
  [offsets : (&mut offsets (Array i64 16))]) : bool
  (when
    (or
      (< alphabet 0)
      (> alphabet 2)
      (< start 0)
      (> start 318)
      (< count 1)
      (> count (- 318 start))
      (< mode 0)
      (> mode 2))
    (return false))
  (let
    [count-start : i64 (* alphabet 16)]
    [maximum : i64 0]
    [symbol-start : i64
      (cond [(= alphabet 0) 0] [(= alphabet 1) 288] [else 320])]
    [capacity : i64 (cond [(= alphabet 0) 288] [(= alphabet 1) 32] [else 19])]
    (when (> count capacity) (return false))
    (for [index (iterator.range 0 16)]
      (set! (array-ref counts (+ count-start index)) 0)
      (set! (array-ref offsets index) 0))
    (for [index (iterator.range 0 count)]
      (let
        [length : i64 (array-ref lengths (+ start index))]
        (when (or (< length 0) (> length 15)) (return false))
        (when (> length maximum) (set! maximum length))
        (set!
          (array-ref counts (+ count-start length))
          (+ (array-ref counts (+ count-start length)) 1))))
    (let
      [nonzero : i64 (- count (array-ref counts count-start))]
      [left : i64 1]
      (for [length (iterator.range 1 16)]
        (set! left (- (* left 2) (array-ref counts (+ count-start length))))
        (when (< left 0) (return false)))
      (when
        (and
          (!= left 0)
          (not (and (= mode 2) (= nonzero 0)))
          (not
            (and
              (> mode 0)
              (= nonzero 1)
              (= (array-ref counts (+ count-start 1)) 1))))
        (return false))
      (for [length (iterator.range 1 15)]
        (set!
          (array-ref offsets (+ length 1))
          (+
            (array-ref offsets length)
            (array-ref counts (+ count-start length)))))
      (for [symbol (iterator.range 0 count)]
        (let
          [length : i64 (array-ref lengths (+ start symbol))]
          (when
            (> length 0)
            (let
              [index : i64 (array-ref offsets length)]
              (when (or (< index 0) (>= index capacity)) (return false))
              (set! (array-ref symbols (+ symbol-start index)) symbol)
              (set! (array-ref offsets length) (+ index 1))))))
      (set! (array-ref counts count-start) maximum)
      true)))

;: Reset the resumable canonical symbol cursor.
(define (deflate-symbol-reset! [state : (&mut state Decoder)]) : unit
  (set! state.symbol-code 0)
  (set! state.symbol-length 1)
  (set! state.symbol-first 0)
  (set! state.symbol-index 0))

;: Return one checked canonical symbol, or -1 on suspension/failure.
;: Select 0 for literal/length, 1 for distance, or 2 for code lengths.
(define (deflate-symbol!
  [state : (&mut state Decoder)]
  [input : (& input bytes)]
  [cursor : (&mut cursor DeflateCursor)]
  [alphabet : i64]) : i64
  (when
    (or (< alphabet 0) (> alphabet 2))
    (deflate-fail! state (InvalidState))
    (return -1))
  (let
    [maximum : i64 (array-ref state.tree-counts (* alphabet 16))]
    (when
      (or (< maximum 0) (> maximum 15))
      (deflate-fail! state (InvalidState))
      (return -1))
    (when (= maximum 0) (deflate-fail! state (InvalidCode)) (return -1))
    (while (<= state.symbol-length maximum)
      (when
        (or
          (< state.symbol-length 1)
          (< state.symbol-code 0)
          (> state.symbol-code 32767)
          (< state.symbol-first 0)
          (> state.symbol-first 32768)
          (< state.symbol-index 0)
          (> state.symbol-index 288))
        (deflate-fail! state (InvalidState))
        (return -1))
      (let
        [bit : i64 (deflate-bit! state input cursor)]
        (when (< bit 0) (return -1))
        (set! state.symbol-code (bit-or (shl state.symbol-code 1) bit)))
      (let
        [length : i64 state.symbol-length]
        [count : i64 (array-ref state.tree-counts (+ (* alphabet 16) length))]
        [offset : i64 (- state.symbol-code state.symbol-first)]
        (when
          (or (< count 0) (> count 288))
          (deflate-fail! state (InvalidState))
          (return -1))
        (when
          (and (>= offset 0) (< offset count))
          (let
            [index : i64 (+ state.symbol-index offset)]
            [capacity : i64
              (cond [(= alphabet 0) 288] [(= alphabet 1) 32] [else 19])]
            [base : i64
              (cond [(= alphabet 0) 0] [(= alphabet 1) 288] [else 320])]
            [symbol : i64
              (if (< index capacity)
                (array-ref state.tree-symbols (+ base index))
                -1)]
            (when
              (or (< symbol 0) (>= symbol capacity))
              (deflate-fail! state (InvalidState))
              (return -1))
            (deflate-symbol-reset! state)
            (return symbol)))
        (set! state.symbol-index (+ state.symbol-index count))
        (set! state.symbol-first (* (+ state.symbol-first count) 2))
        (set! state.symbol-length (+ state.symbol-length 1))))
    (deflate-fail! state (InvalidCode))
    -1))

;: Check a cumulative output count against the ratio without multiplication.
(define (deflate-ratio-allows?
  [limits : (& limits DeflateLimits)]
  [input : i64]
  [output : i64]) : bool
  (and
    (limits-valid? limits)
    (>= input 0)
    (>= output 0)
    (or
      (<= output limits.startup-bytes)
      (and
        (> limits.ratio 0)
        (<= (+ 1 (/ (- (- output limits.startup-bytes) 1) limits.ratio)) input)))))

;: Emit one byte after checking all bounds. False means output suspension or
;: a sticky failure; neither case emits or charges the byte.
(define (deflate-emit!
  [state : (&mut state Decoder)]
  [output : (&mut output bytes)]
  [cursor : (&mut cursor DeflateCursor)]
  [value : i64]) : bool
  (when
    (or
      (< value 0)
      (> value 255)
      (< cursor.output 0)
      (> cursor.output (byte_buf.bytes-mut-length output))
      (< state.total-output 0)
      (> state.total-output state.limits.max-output)
      (< state.limits.window-bytes 0)
      (> state.limits.window-bytes 32768)
      (!= (byte_buf.capacity (& state.history)) state.limits.window-bytes)
      (!= state.history.len state.limits.window-bytes)
      (< state.history-position 0)
      (if (= state.limits.window-bytes 0)
        (!= state.history-position 0)
        (>= state.history-position state.limits.window-bytes)))
    (deflate-fail! state (InvalidState))
    (return false))
  (when
    (= state.total-output 9223372036854775807)
    (deflate-fail! state (Overflow))
    (return false))
  (when
    (= state.total-output state.limits.max-output)
    (deflate-fail! state (OutputLimit))
    (return false))
  (unless
    (deflate-ratio-allows?
      (& state.limits)
      state.total-input
      (+ state.total-output 1))
    (deflate-fail! state (RatioLimit))
    (return false))
  (when
    (or (< state.work 0) (>= state.work state.limits.max-work))
    (deflate-fail! state (WorkLimit))
    (return false))
  (when (= cursor.output (byte_buf.bytes-mut-length output)) (return false))
  (unless (deflate-charge! state 1) (return false))
  (byte_buf.bytes-set! output cursor.output (cast value : u8))
  (set! cursor.output (+ cursor.output 1))
  (set! state.total-output (+ state.total-output 1))
  (when
    (> state.limits.window-bytes 0)
    (set!
      (array-ref state.history.slots state.history-position)
      (cast value : u8))
    (set! state.history-position (+ state.history-position 1))
    (when
      (= state.history-position state.limits.window-bytes)
      (set! state.history-position 0)))
  true)

;: Return a per-call sticky failure, or a pending-output result.
(define (deflate-output-stop
  [state : (& state Decoder)]
  [cursor : (& cursor DeflateCursor)]) : DeflateStep
  (DeflateStep
    cursor.input
    cursor.output
    (if (= state.phase 18)
      (Error (deflate-error-copy (& state.failure)))
      (NeedOutput))))

;: Suspend for input, interpreting explicit EOF only when another byte is needed.
(define (deflate-input-stop!
  [state : (&mut state Decoder)]
  [cursor : (& cursor DeflateCursor)]
  [eof : bool]) : DeflateStep
  (when (and (!= state.phase 18) eof) (deflate-fail! state (Truncated)))
  (DeflateStep
    cursor.input
    cursor.output
    (if (= state.phase 18)
      (Error (deflate-error-copy (& state.failure)))
      (NeedInput))))

;: Advance to the next block or discard only final-byte padding on completion.
(define (deflate-finish-block! [state : (&mut state Decoder)]) : unit
  (if state.final
    (begin
      (set! state.phase 17)
      (set! state.bits 0)
      (set! state.bit-count 0))
    (set! state.phase 0)))

;: The mandated dynamic code-length alphabet permutation.
(define (deflate-code-order [index : i64]) : i64
  (cond
    [(= index 0) 16]
    [(= index 1) 17]
    [(= index 2) 18]
    [(= index 3) 0]
    [(= index 4) 8]
    [(= index 5) 7]
    [(= index 6) 9]
    [(= index 7) 6]
    [(= index 8) 10]
    [(= index 9) 5]
    [(= index 10) 11]
    [(= index 11) 4]
    [(= index 12) 12]
    [(= index 13) 3]
    [(= index 14) 13]
    [(= index 15) 2]
    [(= index 16) 14]
    [(= index 17) 1]
    [else 15]))

;: Build both fixed alphabets, charging before any workspace mutation.
(define (deflate-fixed! [state : (&mut state Decoder)]) : bool
  (unless
    (deflate-state-valid? state)
    (deflate-fail! state (InvalidState))
    (return false))
  (unless (deflate-charge! state 1054) (return false))
  (for [symbol (iterator.range 0 288)]
    (set!
      (array-ref state.lengths symbol)
      (cond [(< symbol 144) 8] [(< symbol 256) 9] [(< symbol 280) 7] [else 8])))
  (unless
    (deflate-build-tree!
      (&mut state.tree-counts)
      (&mut state.tree-symbols)
      (& state.lengths)
      0
      288
      0
      0
      (&mut state.offsets))
    (deflate-fail! state (InvalidState))
    (return false))
  (for [symbol (iterator.range 0 32)]
    (set! (array-ref state.lengths symbol) 5))
  (unless
    (deflate-build-tree!
      (&mut state.tree-counts)
      (&mut state.tree-symbols)
      (& state.lengths)
      0
      32
      1
      0
      (&mut state.offsets))
    (deflate-fail! state (InvalidState))
    (return false))
  true)

;: Build the dynamic code-length alphabet after its last field.
(define (deflate-build-code! [state : (&mut state Decoder)]) : bool
  (unless
    (deflate-state-valid? state)
    (deflate-fail! state (InvalidState))
    (return false))
  (unless (deflate-charge! state 85) (return false))
  (unless
    (deflate-build-tree!
      (&mut state.tree-counts)
      (&mut state.tree-symbols)
      (& state.lengths)
      0
      19
      2
      0
      (&mut state.offsets))
    (deflate-fail! state (MalformedTree))
    (return false))
  (deflate-symbol-reset! state)
  (set! state.length-index 0)
  (set! state.phase 9)
  true)

;: Build dynamic literal and distance tables after the combined length sequence.
(define (deflate-build-alphabets! [state : (&mut state Decoder)]) : bool
  (unless
    (deflate-state-valid? state)
    (deflate-fail! state (InvalidState))
    (return false))
  (when
    (= (array-ref state.lengths 256) 0)
    (deflate-fail! state (MalformedTree))
    (return false))
  (unless
    (deflate-charge!
      state
      (+ 94 (* 2 (+ state.literal-count state.distance-count))))
    (return false))
  (unless
    (and
      (deflate-build-tree!
        (&mut state.tree-counts)
        (&mut state.tree-symbols)
        (& state.lengths)
        0
        state.literal-count
        0
        1
        (&mut state.offsets))
      (deflate-build-tree!
        (&mut state.tree-counts)
        (&mut state.tree-symbols)
        (& state.lengths)
        state.literal-count
        state.distance-count
        1
        2
        (&mut state.offsets)))
    (deflate-fail! state (MalformedTree))
    (return false))
  (deflate-symbol-reset! state)
  (set! state.phase 11)
  true)

;: Set the base and extra-bit width for a checked length symbol.
(define (deflate-length! [state : (&mut state Decoder)] [symbol : i64]) : unit
  (cond
    [(or (< symbol 257) (> symbol 287)) (deflate-fail! state (InvalidState))]
    [(> symbol 285) (deflate-fail! state (ReservedEncoding))]
    [(= symbol 285)
      (set! state.pending-length 258)
      (set! state.repeat-extra 0)
      (set! state.phase 12)]
    [(< symbol 265)
      (set! state.pending-length (- symbol 254))
      (set! state.repeat-extra 0)
      (set! state.phase 12)]
    [else
      (let
        [extra : i64 (+ 1 (/ (- symbol 265) 4))]
        [base : i64 (+ 3 (shl (+ 4 (% (- symbol 265) 4)) extra))]
        (set! state.pending-length base)
        (set! state.repeat-extra extra)
        (set! state.phase 12))]))

;: Set the base and extra-bit width for a checked distance symbol.
(define (deflate-distance! [state : (&mut state Decoder)] [symbol : i64]) : unit
  (cond
    [(or (< symbol 0) (> symbol 31)) (deflate-fail! state (InvalidState))]
    [(> symbol 29) (deflate-fail! state (ReservedEncoding))]
    [(< symbol 4)
      (set! state.pending-distance (+ symbol 1))
      (set! state.repeat-extra 0)
      (set! state.phase 14)]
    [else
      (let
        [extra : i64 (- (/ symbol 2) 1)]
        [base : i64 (+ 1 (shl (+ 2 (% symbol 2)) extra))]
        (set! state.pending-distance base)
        (set! state.repeat-extra extra)
        (set! state.phase 14))]))

;: Decode as far as caller chunks permit, without retaining a chunk borrow.
;: EOF applies to this chunk's end; retries supply its unconsumed suffix.
;: Final padding bits are ignored, and no following byte is read. Empty output
;: may finish an empty member. Limit failures precede output suspension.
(define (step!
  [state : (&mut state Decoder)]
  [input : (& input bytes)]
  [output : (&mut output bytes)]
  [eof : bool]) : DeflateStep
  (let
    [cursor : DeflateCursor (DeflateCursor 0 0)]
    (unless
      (deflate-state-valid? state)
      (deflate-fail! state (InvalidState))
      (return (deflate-output-stop state (& cursor))))
    (while (< state.phase 17)
      (cond
        [(= state.phase 0)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 1)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (set! state.final (!= value 0))
            (set! state.phase 1))]
        [(= state.phase 1)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 2)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (cond
              [(= value 0)
                (set! state.bits 0)
                (set! state.bit-count 0)
                (set! state.phase 2)]
              [(= value 1)
                (when
                  (deflate-fixed! state)
                  (deflate-symbol-reset! state)
                  (set! state.phase 11))]
              [(= value 2)
                (unless
                  (deflate-charge! state 19)
                  (return (deflate-output-stop state (& cursor))))
                (for [index (iterator.range 0 19)]
                  (set! (array-ref state.lengths index) 0))
                (set! state.length-index 0)
                (set! state.phase 5)]
              [else (deflate-fail! state (ReservedEncoding))]))]
        [(= state.phase 2)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 16)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (set! state.stored-left value)
            (set! state.phase 3))]
        [(= state.phase 3)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 16)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (if (= value (- 65535 state.stored-left))
              (set! state.phase 4)
              (deflate-fail! state (MalformedBlock))))]
        [(= state.phase 4)
          (if (= state.stored-left 0)
            (deflate-finish-block! state)
            (let
              [value : i64 (deflate-field! state input (&mut cursor) 8)]
              (when
                (< value 0)
                (return (deflate-input-stop! state (& cursor) eof)))
              (set! state.stored-left (- state.stored-left 1))
              (set! state.pending-value value)
              (set! state.after-literal 4)
              (set! state.phase 15)))]
        [(= state.phase 5)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 5)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (if (> value 29)
              (deflate-fail! state (ReservedEncoding))
              (begin
                (set! state.literal-count (+ 257 value))
                (set! state.phase 6))))]
        [(= state.phase 6)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 5)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (set! state.distance-count (+ 1 value))
            (set! state.phase 7))]
        [(= state.phase 7)
          (let
            [value : i64 (deflate-field! state input (&mut cursor) 4)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (set! state.code-count (+ 4 value))
            (set! state.phase 8))]
        [(= state.phase 8)
          (if (= state.length-index state.code-count)
            (begin
              (deflate-build-code! state)
              unit)
            (let
              [value : i64 (deflate-field! state input (&mut cursor) 3)]
              (when
                (< value 0)
                (return (deflate-input-stop! state (& cursor) eof)))
              (when
                (> state.length-index state.code-count)
                (deflate-fail! state (InvalidState))
                (return (deflate-output-stop state (& cursor))))
              (set!
                (array-ref
                  state.lengths
                  (deflate-code-order state.length-index))
                value)
              (set! state.length-index (+ state.length-index 1))
              unit))]
        [(= state.phase 9)
          (if (=
            state.length-index
            (+ state.literal-count state.distance-count))
            (begin
              (deflate-build-alphabets! state)
              unit)
            (let
              [symbol : i64 (deflate-symbol! state input (&mut cursor) 2)]
              (when
                (< symbol 0)
                (return (deflate-input-stop! state (& cursor) eof)))
              (when
                (>=
                  state.length-index
                  (+ state.literal-count state.distance-count))
                (deflate-fail! state (InvalidState))
                (return (deflate-output-stop state (& cursor))))
              (if (< symbol 16)
                (begin
                  (unless
                    (deflate-charge! state 1)
                    (return (deflate-output-stop state (& cursor))))
                  (set! (array-ref state.lengths state.length-index) symbol)
                  (set! state.length-index (+ state.length-index 1)))
                (begin
                  (when
                    (and (= symbol 16) (= state.length-index 0))
                    (deflate-fail! state (MalformedTree))
                    (return (deflate-output-stop state (& cursor))))
                  (set!
                    state.repeat-value
                    (if (= symbol 16)
                      (array-ref state.lengths (- state.length-index 1))
                      0))
                  (set!
                    state.repeat-base
                    (if (= symbol 18)
                      11
                      3))
                  (set!
                    state.repeat-extra
                    (cond [(= symbol 16) 2] [(= symbol 17) 3] [else 7]))
                  (set! state.phase 10)))
              unit))]
        [(= state.phase 10)
          (let
            [value : i64
              (deflate-field! state input (&mut cursor) state.repeat-extra)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (let
              [count : i64 (+ state.repeat-base value)]
              [remaining : i64
                (-
                  (+ state.literal-count state.distance-count)
                  state.length-index)]
              (when
                (or (< remaining 0) (> count remaining))
                (deflate-fail! state (MalformedTree))
                (return (deflate-output-stop state (& cursor))))
              (unless
                (deflate-charge! state count)
                (return (deflate-output-stop state (& cursor))))
              (for [index (iterator.range 0 count)]
                (set!
                  (array-ref state.lengths state.length-index)
                  state.repeat-value)
                (set! state.length-index (+ state.length-index 1)))
              (set! state.phase 9)))]
        [(= state.phase 11)
          (let
            [symbol : i64 (deflate-symbol! state input (&mut cursor) 0)]
            (when
              (< symbol 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (cond
              [(< symbol 256)
                (set! state.pending-value symbol)
                (set! state.after-literal 11)
                (set! state.phase 15)]
              [(= symbol 256) (deflate-finish-block! state)]
              [else (deflate-length! state symbol)]))]
        [(= state.phase 12)
          (let
            [value : i64
              (deflate-field! state input (&mut cursor) state.repeat-extra)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (set! state.pending-length (+ state.pending-length value))
            (set! state.phase 13))]
        [(= state.phase 13)
          (let
            [symbol : i64 (deflate-symbol! state input (&mut cursor) 1)]
            (when
              (< symbol 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (deflate-distance! state symbol))]
        [(= state.phase 14)
          (let
            [value : i64
              (deflate-field! state input (&mut cursor) state.repeat-extra)]
            (when
              (< value 0)
              (return (deflate-input-stop! state (& cursor) eof)))
            (set! state.pending-distance (+ state.pending-distance value))
            (cond
              [(or
                  (< state.pending-distance 1)
                  (> state.pending-distance state.total-output))
                (deflate-fail! state (InvalidDistance))]
              [(> state.pending-distance state.limits.window-bytes)
                (deflate-fail! state (WindowLimit))]
              [else (set! state.phase 16)]))]
        [(= state.phase 15)
          (unless
            (deflate-emit! state output (&mut cursor) state.pending-value)
            (return (deflate-output-stop state (& cursor))))
          (set! state.phase state.after-literal)]
        [else
          (when
            (or
              (< state.pending-length 1)
              (> state.pending-length 258)
              (< state.pending-distance 1)
              (> state.pending-distance state.total-output)
              (> state.pending-distance state.limits.window-bytes))
            (deflate-fail! state (InvalidState))
            (return (deflate-output-stop state (& cursor))))
          (let
            [index : i64 (- state.history-position state.pending-distance)]
            (when (< index 0) (set! index (+ index state.limits.window-bytes)))
            (unless
              (deflate-emit!
                state
                output
                (&mut cursor)
                (cast (array-ref state.history.slots index) : i64))
              (return (deflate-output-stop state (& cursor))))
            (set! state.pending-length (- state.pending-length 1))
            (when (= state.pending-length 0) (set! state.phase 11)))]))
    (DeflateStep
      cursor.input
      cursor.output
      (if (= state.phase 17)
        (Done)
        (Error (deflate-error-copy (& state.failure)))))))

;: Grow a wrapper's output within its validated limit, checking before allocation.
;: Returns false for malformed storage or an exhausted capacity limit.
(define (deflate-grow-output! [buf : (&mut buf byte_buf.ByteBuf)] [limit : i64]) : bool
  (let
    [capacity : i64 (array-length buf.slots)]
    (when
      (or (< limit 0) (< buf.len 0) (> buf.len capacity) (>= capacity limit))
      (return false))
    (let
      [increment : i64
        (if (= capacity 0)
          (if (< limit 256)
            limit
            256)
          (if (< capacity (- limit capacity))
            capacity
            (- limit capacity)))]
      [next : i64 (+ capacity increment)]
      [slots : (__tl_dyn-array u8) (__tl_make-array u8 next)]
      (for [index (iterator.range 0 buf.len)]
        (set! (array-ref slots index) (array-ref buf.slots index)))
      (set! buf.slots slots)
      true)))

;: Decode one raw member using the same bounded engine as `step!`.
;: Returns its exact compressed byte length, leaving trailing input untouched.
;: Output capacity never exceeds max-output. Including a capped final growth,
;: all retained output backing arrays total less than three times max-output.
(define (decode [input : (& input bytes)] [limits : (& limits DeflateLimits)]) : DeflateDecodeResult
  (match (decoder-new limits)
    [(DeflateNewErr error) (DeflateDecodeErr error)]
    [(DeflateNewOk state)
      (let
        [out : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 0))]
        [consumed : i64 0]
        [limit : i64 state.limits.max-output]
        (while true
          (let
            [live : i64 out.len]
            [capacity : i64 (array-length out.slots)]
            (set! out.len capacity)
            (let
              [result : DeflateStep
                (step!
                  (&mut state)
                  (byte_buf.bytes-slice-view
                    input
                    consumed
                    (- (byte_buf.bytes-length input) consumed))
                  (byte_buf.bytes-mut-slice-view
                    (byte_buf.as-mut-bytes (&mut out))
                    live
                    (- capacity live))
                  true)]
              (set! consumed (+ consumed result.consumed))
              (set! out.len (+ live result.produced))
              (match result.status
                [(Done)
                  (return (DeflateDecodeOk (DeflateDecoded out consumed)))]
                [(Error error) (return (DeflateDecodeErr error))]
                [(NeedInput)
                  (return
                    (DeflateDecodeErr
                      (DeflateError (Truncated) consumed out.len)))]
                [(NeedOutput)
                  (unless
                    (deflate-grow-output! (&mut out) limit)
                    (return
                      (DeflateDecodeErr
                        (DeflateError (OutputLimit) consumed out.len))))]))))
        (DeflateDecodeErr (DeflateError (InvalidState) consumed out.len)))]))