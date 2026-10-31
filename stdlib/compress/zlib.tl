;# Bounded incremental zlib decoding (RFC 1950).
;#
;# `decoder-new` validates limits and allocates the raw DEFLATE history once.
;# `step!` parses the header, an optional preset-dictionary identifier, the raw
;# body through `stdlib.compress.deflate` and the Adler-32 trailer. It borrows
;# chunks per call, reports exact counts and never allocates. One member is
;# consumed; following bytes stay with the caller. `Done` follows only a
;# matching trailer, so earlier output is tentative.
;#
;# Usage: `(import stdlib.compress.zlib)` with `deflate.default-limits` and a
;# dictionary policy. See `docs/zlib.md` and `examples/zlib_decode.tl`.
(import stdlib.byte_buf)
(import stdlib.compress.adler32)
(import stdlib.compress.deflate)

;: Stable failure categories: every raw DEFLATE kind plus zlib framing kinds.
(defenum ZlibErrorKind
  (InvalidLimits)
  (InvalidState)
  (InvalidMethod)
  (InvalidWindow)
  (InvalidHeaderCheck)
  (DictionaryForbidden)
  (DictionaryRequired i64)
  (DictionaryMismatch)
  (ChecksumMismatch)
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

;: A failure at cumulative member-input and emitted-output byte counts.
(defstruct ZlibError
  (kind ZlibErrorKind)
  (input i64)
  (output i64))

;: Whether a member may name a preset dictionary. Git objects forbid one.
(defenum ZlibDictionaryPolicy
  (ForbidDictionary)
  (AllowDictionary))

;: Owning resumable state. Public fields are checked; do not mutate them.
;: Phases: 0 header, 1 dictionary identifier, 2 awaiting a dictionary, 3 body,
;: 4 trailer, 5 Done and 6 a sticky failure. `framing` counts header bytes
;: until the body starts and trailer bytes after it ends.
(defstruct Decoder
  (raw deflate.Decoder)
  (allow-dictionary bool)
  (phase i64)
  (field i64)
  (field-read i64)
  (framing i64)
  (dictionary-id i64)
  (checksum i64)
  (failure ZlibError))

;: Construction result, including invalid limits or insufficient initial work.
(defenum ZlibNewResult
  (ZlibNewOk Decoder)
  (ZlibNewErr ZlibError))

;: Outcome of an incremental call. `NeedDictionary` carries the identifier and
;: repeats until `set-dictionary!`. A terminal outcome is repeated unchanged.
(defenum ZlibStatus
  (NeedInput)
  (NeedOutput)
  (NeedDictionary i64)
  (Done)
  (Error ZlibError))

;: Per-call counts, including partial progress before a suspension or error.
(defstruct ZlibStep
  (consumed i64)
  (produced i64)
  (status ZlibStatus))

;: Dictionary installation outcome; a rejection after a check is sticky.
(defenum ZlibDictionaryResult
  (DictionaryAccepted)
  (DictionaryRejected ZlibError))

;: One-shot result: owned output and the exact member length.
(defenum ZlibDecodeResult
  (ZlibDecodeOk deflate.DeflateDecoded)
  (ZlibDecodeErr ZlibError))

;: The same category for a raw decoder failure.
(define (zlib-raw-kind [kind : (& kind deflate.DeflateErrorKind)]) : ZlibErrorKind
  (match kind
    [(deflate.InvalidLimits) (InvalidLimits)]
    [(deflate.InvalidState) (InvalidState)]
    [(deflate.MalformedBlock) (MalformedBlock)]
    [(deflate.MalformedTree) (MalformedTree)]
    [(deflate.InvalidCode) (InvalidCode)]
    [(deflate.Truncated) (Truncated)]
    [(deflate.ReservedEncoding) (ReservedEncoding)]
    [(deflate.InvalidDistance) (InvalidDistance)]
    [(deflate.Overflow) (Overflow)]
    [(deflate.InputLimit) (InputLimit)]
    [(deflate.OutputLimit) (OutputLimit)]
    [(deflate.WindowLimit) (WindowLimit)]
    [(deflate.WorkLimit) (WorkLimit)]
    [(deflate.RatioLimit) (RatioLimit)]))

;: Construct a decoder; all allocation is the raw decoder's bounded history.
(define (decoder-new
  [limits : (& limits deflate.DeflateLimits)]
  [policy : (& policy ZlibDictionaryPolicy)]) : ZlibNewResult
  (match (deflate.decoder-new limits)
    [(deflate.DeflateNewErr error)
      (ZlibNewErr
        (ZlibError (zlib-raw-kind (& error.kind)) error.input error.output))]
    [(deflate.DeflateNewOk raw)
      (ZlibNewOk
        (Decoder
          raw
          (match policy
            [(ForbidDictionary) false]
            [(AllowDictionary) true])
          0
          0
          0
          0
          -1
          (adler32.initial)
          (ZlibError (InvalidState) 0 0)))]))

;: Member bytes accepted so far, including framing.
(define (input-total [state : (& state Decoder)]) : i64
  (+ state.raw.total-input state.framing))

;: Decoded bytes emitted so far; they are tentative until `Done`.
(define (output-total [state : (& state Decoder)]) : i64
  state.raw.total-output)

;: Work charged so far, including framing and dictionary bytes.
(define (work-total [state : (& state Decoder)]) : i64
  (+ state.raw.work state.framing))

;: Copy a failure without retaining any caller storage.
(define (zlib-error-copy [error : (& error ZlibError)]) : ZlibError
  (ZlibError (clone error.kind) error.input error.output))

;: Enter the sticky failed phase.
(define (zlib-fail! [state : (&mut state Decoder)] [kind : ZlibErrorKind]) : unit
  (let
    [input : i64 (input-total state)]
    (set! state.phase 6)
    (set! state.failure (ZlibError kind input state.raw.total-output))))

;: Bytes in the field read by `phase`. A failure may interrupt any field;
;: other phases keep no partial field.
(define (zlib-width [phase : i64]) : i64
  (cond [(= phase 0) 2] [(or (= phase 1) (= phase 4) (= phase 6)) 4] [else 1]))

;: Check public state shapes and framing counts before an active call.
(define (zlib-state-valid? [state : (& state Decoder)]) : bool
  (and
    (deflate.limits-valid? (& state.raw.limits))
    (>= state.raw.total-input 0)
    (<= state.raw.total-input state.raw.limits.max-input)
    (>= state.raw.work 0)
    (<= state.raw.work state.raw.limits.max-work)
    (>= state.phase 0)
    (<= state.phase 6)
    (>= state.field-read 0)
    (< state.field-read (zlib-width state.phase))
    (>= state.field 0)
    (< state.field (shl 1 (* 8 state.field-read)))
    (>= state.framing 0)
    (<= state.framing (- state.raw.limits.max-input state.raw.total-input))
    (<= state.framing (- state.raw.limits.max-work state.raw.work))
    (>= state.dictionary-id -1)
    (<= state.dictionary-id 4294967295)
    (>= state.checksum 0)
    (< (bit-and state.checksum 65535) 65521)
    (< (shr state.checksum 16) 65521)
    (cond
      [(= state.phase 0)
        (and (= state.raw.phase 0) (= state.framing state.field-read))]
      [(= state.phase 1)
        (and (= state.raw.phase 0) (= state.framing (+ 2 state.field-read)))]
      [(= state.phase 2) (and (= state.raw.phase 0) (= state.framing 6))]
      [(= state.phase 3) (= state.framing 0)]
      [(= state.phase 4)
        (and (= state.raw.phase 17) (= state.framing state.field-read))]
      [(= state.phase 5) (and (= state.raw.phase 17) (= state.framing 4))]
      [else true])))

;: Return the sticky failure when present, or `status`.
(define (zlib-stop
  [state : (& state Decoder)]
  [cursor : (& cursor deflate.DeflateCursor)]
  [status : ZlibStatus]) : ZlibStep
  (ZlibStep
    cursor.input
    cursor.output
    (if (= state.phase 6)
      (Error (zlib-error-copy (& state.failure)))
      status)))

;: Suspend for input, interpreting explicit EOF only when another byte is needed.
(define (zlib-input-stop!
  [state : (&mut state Decoder)]
  [cursor : (& cursor deflate.DeflateCursor)]
  [eof : bool]) : ZlibStep
  (when (and (!= state.phase 6) eof) (zlib-fail! state (Truncated)))
  (zlib-stop state cursor (NeedInput)))

;: Read the rest of a big-endian field, returning -1 on suspension or failure.
;: Byte availability precedes the input and work limits, as in the raw decoder.
(define (zlib-field!
  [state : (&mut state Decoder)]
  [input : (& input bytes)]
  [cursor : (&mut cursor deflate.DeflateCursor)]
  [width : i64]) : i64
  (while (< state.field-read width)
    (when (>= cursor.input (byte_buf.bytes-length input)) (return -1))
    (when
      (>= state.framing (- state.raw.limits.max-input state.raw.total-input))
      (zlib-fail! state (InputLimit))
      (return -1))
    (when
      (>= state.framing (- state.raw.limits.max-work state.raw.work))
      (zlib-fail! state (WorkLimit))
      (return -1))
    (set!
      state.field
      (+
        (* state.field 256)
        (cast (byte_buf.bytes-ref input cursor.input) : i64)))
    (set! state.field-read (+ state.field-read 1))
    (set! state.framing (+ state.framing 1))
    (set! cursor.input (+ cursor.input 1)))
  (let
    [value : i64 state.field]
    (set! state.field 0)
    (set! state.field-read 0)
    value))

;: Move accepted header bytes into the raw counters, preload any dictionary
;: and start the body.
(define (zlib-body!
  [state : (&mut state Decoder)]
  [dictionary : (& dictionary bytes)]) : unit
  (if (deflate.decoder-prime! (&mut state.raw) state.framing dictionary)
    (begin
      (set! state.framing 0)
      (set! state.phase 3))
    (zlib-fail!
      state
      (if (= state.raw.phase 18)
        (zlib-raw-kind (& state.raw.failure.kind))
        (InvalidState)))))

;: Check CMF/FLG in zlib's order, then await a dictionary or start the body.
(define (zlib-header!
  [state : (&mut state Decoder)]
  [header : i64]
  [empty : (& empty bytes)]) : unit
  (let
    [cmf : i64 (shr header 8)]
    (cond
      [(!= (% header 31) 0) (zlib-fail! state (InvalidHeaderCheck))]
      [(!= (bit-and cmf 15) 8) (zlib-fail! state (InvalidMethod))]
      [(> cmf 127) (zlib-fail! state (InvalidWindow))]
      [(> (shl 1 (+ (shr cmf 4) 8)) state.raw.limits.window-bytes)
        (zlib-fail! state (WindowLimit))]
      [(= (bit-and header 32) 0) (zlib-body! state empty)]
      [state.allow-dictionary (set! state.phase 1)]
      [else (zlib-fail! state (DictionaryForbidden))])))

;: Supply the dictionary named by `NeedDictionary`. A mismatch or work-limit
;: failure is sticky; a call in any other phase is rejected without change.
(define (set-dictionary!
  [state : (&mut state Decoder)]
  [dictionary : (& dictionary bytes)]) : ZlibDictionaryResult
  (unless
    (and (zlib-state-valid? state) (= state.phase 2))
    (return
      (DictionaryRejected
        (ZlibError (InvalidState) (input-total state) state.raw.total-output))))
  (zlib-body! state dictionary)
  (when
    (and
      (= state.phase 3)
      (!= (adler32.checksum dictionary) state.dictionary-id))
    (zlib-fail! state (DictionaryMismatch)))
  (if (= state.phase 6)
    (DictionaryRejected (zlib-error-copy (& state.failure)))
    (DictionaryAccepted)))

;: Decode as far as caller chunks permit, without retaining a chunk borrow.
;: EOF applies to this chunk's end; retries supply its unconsumed suffix.
;: No byte after the trailer is read. A checksum failure never reports Done.
(define (step!
  [state : (&mut state Decoder)]
  [input : (& input bytes)]
  [output : (&mut output bytes)]
  [eof : bool]) : ZlibStep
  (let
    [cursor : deflate.DeflateCursor (deflate.DeflateCursor 0 0)]
    (unless
      (zlib-state-valid? state)
      (zlib-fail! state (InvalidState))
      (return (zlib-stop state (& cursor) (Done))))
    (while (< state.phase 5)
      (cond
        [(= state.phase 0)
          (let
            [header : i64 (zlib-field! state input (&mut cursor) 2)]
            (when (< header 0) (return (zlib-input-stop! state (& cursor) eof)))
            (zlib-header! state header (byte_buf.bytes-slice-view input 0 0)))]
        [(= state.phase 1)
          (let
            [id : i64 (zlib-field! state input (&mut cursor) 4)]
            (when (< id 0) (return (zlib-input-stop! state (& cursor) eof)))
            (set! state.dictionary-id id)
            (set! state.phase 2))]
        [(= state.phase 2)
          (return
            (zlib-stop state (& cursor) (NeedDictionary state.dictionary-id)))]
        [(= state.phase 3)
          (let
            [start : i64 cursor.output]
            [result : deflate.DeflateStep
              (deflate.step!
                (&mut state.raw)
                (byte_buf.bytes-slice-view
                  input
                  cursor.input
                  (- (byte_buf.bytes-length input) cursor.input))
                (byte_buf.bytes-mut-slice-view
                  output
                  start
                  (- (byte_buf.bytes-mut-length output) start))
                eof)]
            (set! cursor.input (+ cursor.input result.consumed))
            (set! cursor.output (+ start result.produced))
            (set!
              state.checksum
              (adler32.update
                state.checksum
                (byte_buf.bytes-slice-view output start result.produced)))
            (match result.status
              [(deflate.Done) (set! state.phase 4)]
              [(deflate.NeedInput)
                (return (zlib-stop state (& cursor) (NeedInput)))]
              [(deflate.NeedOutput)
                (return (zlib-stop state (& cursor) (NeedOutput)))]
              [(deflate.Error error)
                (set! state.phase 6)
                (set!
                  state.failure
                  (ZlibError
                    (zlib-raw-kind (& error.kind))
                    error.input
                    error.output))]))]
        [else
          (let
            [value : i64 (zlib-field! state input (&mut cursor) 4)]
            (when (< value 0) (return (zlib-input-stop! state (& cursor) eof)))
            (if (= value state.checksum)
              (set! state.phase 5)
              (zlib-fail! state (ChecksumMismatch))))]))
    (zlib-stop state (& cursor) (Done))))

;: Decode one member with the shared engine. Without a supplied dictionary,
;: FDICT reports DictionaryForbidden or DictionaryRequired with its identifier.
(define (zlib-decode
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [policy : (& policy ZlibDictionaryPolicy)]
  [supplied : bool]
  [dictionary : (& dictionary bytes)]) : ZlibDecodeResult
  (match (decoder-new limits policy)
    [(ZlibNewErr error) (ZlibDecodeErr error)]
    [(ZlibNewOk state)
      (let
        [out : byte_buf.ByteBuf (byte_buf.from-array (__tl_make-array u8 0))]
        [consumed : i64 0]
        [limit : i64 state.raw.limits.max-output]
        (while true
          (let
            [live : i64 out.len]
            [capacity : i64 (array-length out.slots)]
            (set! out.len capacity)
            (let
              [result : ZlibStep
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
                  (return (ZlibDecodeOk (deflate.DeflateDecoded out consumed)))]
                [(Error error) (return (ZlibDecodeErr error))]
                [(NeedDictionary id)
                  (unless
                    supplied
                    (return
                      (ZlibDecodeErr
                        (ZlibError (DictionaryRequired id) consumed out.len))))
                  (match (set-dictionary! (&mut state) dictionary)
                    [(DictionaryAccepted) unit]
                    [(DictionaryRejected error) (return (ZlibDecodeErr error))])]
                [(NeedInput)
                  (return
                    (ZlibDecodeErr (ZlibError (Truncated) consumed out.len)))]
                [(NeedOutput)
                  (unless
                    (deflate.deflate-grow-output! (&mut out) limit)
                    (return
                      (ZlibDecodeErr (ZlibError (OutputLimit) consumed out.len))))]))))
        (ZlibDecodeErr (ZlibError (InvalidState) consumed out.len)))]))

;: Decode one member without a dictionary. Its output capacity never exceeds
;: max-output; `consumed` excludes trailing container bytes.
(define (decode
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [policy : (& policy ZlibDictionaryPolicy)]) : ZlibDecodeResult
  (zlib-decode input limits policy false (byte_buf.bytes-slice-view input 0 0)))

;: Decode one member that may name `dictionary`; a member that names none
;: leaves it unused.
(define (decode-with-dictionary
  [input : (& input bytes)]
  [limits : (& limits deflate.DeflateLimits)]
  [dictionary : (& dictionary bytes)]) : ZlibDecodeResult
  (zlib-decode input limits (& (AllowDictionary)) true dictionary))