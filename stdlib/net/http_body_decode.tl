;# Bounded borrowed HTTP/1.1 response-body decoding for no-body, fixed-length,
;# and close-delimited framing.
;#
;# A decoder starts only from the response head's typed `HttpResponseBodyPlan`
;# and never inspects `Content-Length` or `Transfer-Encoding` again. Each feed
;# reports the exact prefix of the caller's input it consumed and exactly one
;# outcome: `NeedInput`, `Data` (a borrowed view of that same input, tied to its
;# lifetime and never copied or retained by the decoder), terminal `Complete`,
;# or terminal `Error`. Bytes after a self-delimited body stay in the caller's
;# input for the exchange layer. Terminal states are idempotent: later feeds
;# consume nothing and repeat the same outcome, and a transport signal after a
;# self-delimited body completed cannot make it incomplete.
;#
;# No body byte is allocated or copied, and these modes keep constant-size
;# state. Chunked framing (#7324) and trailer parsing (#7323) extend this
;# decoder; until #7324 lands a chunked plan is rejected explicitly. The module
;# performs no I/O: transport completion arrives as a typed terminal signal.
;#
;# Usage: `(import stdlib.net.http_body_decode)`.
(import stdlib.byte_buf)
(import stdlib.net.http_types)

;: Optional finite bound on decoded body bytes.
(defenum HttpBodyTotalLimit
  (HttpBodyTotalUnlimited)
  (HttpBodyTotalAtMost i64))

;: Caller bounds, validated before any body input. `max-step-bytes` bounds the
;: data one feed may return and must be positive. `max-scratch-bytes` bounds
;: retained framing scratch; the modes here keep none, and chunked framing
;: (#7324) holds its size lines within it.
(defstruct HttpBodyDecodeLimits
  (max-step-bytes i64)
  (total HttpBodyTotalLimit)
  (max-scratch-bytes i64))

;: The transport the body arrives on. It decides which terminal signal ends a
;: close-delimited body (RFC 9112 sections 6.3 and 9.8).
(defenum HttpBodyTransport
  (HttpBodyPlainTransport)
  (HttpBodyTlsTransport))

;: A typed end of the transport stream. `OrderlyEof` is a clean end of the
;: byte stream with no underlying error; on TLS it is an incomplete close
;: unless `TlsCloseNotify` (the peer's authenticated closure alert) came first.
(defenum HttpBodyTerminalSignal
  (HttpBodyOrderlyEof)
  (HttpBodyTlsCloseNotify)
  (HttpBodyTlsAlert)
  (HttpBodyReset)
  (HttpBodyTimeout)
  (HttpBodyCancelled)
  (HttpBodyIoFailure))

;: The wire framing of the plan a decoder was initialized from.
(defenum HttpBodyMode
  (HttpBodyModeNone)
  (HttpBodyModeFixed)
  (HttpBodyModeCloseDelimited)
  (HttpBodyModeChunked))

;: Where a failure was detected.
(defenum HttpBodyPhase
  (HttpBodyPhaseInit)
  (HttpBodyPhaseFeed)
  (HttpBodyPhaseTerminal))

;: Stable failure categories.
(defenum HttpBodyErrorKind
  (HttpBodyInvalidLimits)
  (HttpBodyInvalidFixedLength)
  (HttpBodyUnsupportedTransferCoding http_types.HttpWireFraming)
  (HttpBodyChunkedUnsupported)
  (HttpBodyFixedLengthExceedsTotal)
  (HttpBodyTotalExceeded)
  (HttpBodyCounterOverflow)
  (HttpBodyInvalidTerminalSignal HttpBodyTerminalSignal)
  (HttpBodyIncomplete HttpBodyTerminalSignal))

;: A failure with its mode, phase, and the wire and decoded byte counts reached
;: before it. Every failure leaves the body unread or incomplete, so the
;: connection cannot carry another exchange.
(defstruct HttpBodyDecodeError
  (kind HttpBodyErrorKind)
  (mode HttpBodyMode)
  (phase HttpBodyPhase)
  (wire-consumed i64)
  (decoded i64))

;: How a successful body ended at codec level. `ReuseEligible` bodies delimit
;: themselves (no-body, fixed, and later chunked); a close-delimited body ends
;: with the connection. The exchange layer still applies HTTP version,
;: `Connection`, and transport policy before any reuse.
(defenum HttpBodyCompletionKind
  (HttpBodyReuseEligible)
  (HttpBodyMustClose))

;: The terminal success record. `trailers` is always the empty collection for
;: the modes here; chunked framing fills it after #7323 validates a section.
(defstruct HttpBodyCompletion
  (kind HttpBodyCompletionKind)
  (wire-consumed i64)
  (decoded i64)
  (trailers http_types.HttpHeaders))

;: One closed disposition instead of independent booleans.
(defenum HttpBodyDisposition
  (HttpBodyOpen)
  (HttpBodyReuseEligibleComplete)
  (HttpBodyMustCloseComplete)
  (HttpBodyPoisonedIncomplete HttpBodyDecodeError))

;: Decoder state. `Fixed` holds the declared bytes still expected.
(defenum HttpBodyDecoderState
  (HttpBodyStateFixed i64)
  (HttpBodyStateCloseDelimited)
  (HttpBodyStateComplete HttpBodyCompletionKind)
  (HttpBodyStateFailed HttpBodyDecodeError))

;: A decoder. It owns no input and no body bytes; `wire-consumed` and
;: `decoded` are checked totals over all feeds, equal in these modes.
(defstruct HttpBodyDecoder
  (mode HttpBodyMode)
  (transport HttpBodyTransport)
  (limits HttpBodyDecodeLimits)
  (wire-consumed i64)
  (decoded i64)
  (state HttpBodyDecoderState))

;: Construction result. An error consumed no input.
(defenum HttpBodyDecoderNewResult
  (HttpBodyDecoderNewOk HttpBodyDecoder)
  (HttpBodyDecoderNewErr HttpBodyDecodeError))

;: The single outcome of one feed. `Data` holds a view of the fed input and the
;: next decoder, which may already be complete after the final fixed view.
(defenum HttpBodyStep
  (:lifetimes input)
  (HttpBodyNeedInput HttpBodyDecoder)
  (HttpBodyData (& input bytes) HttpBodyDecoder)
  (HttpBodyComplete HttpBodyDecoder HttpBodyCompletion)
  (HttpBodyError HttpBodyDecoder HttpBodyDecodeError))

;: One feed result. `consumed` is the exact prefix of this call's input that
;: belonged to the body; everything after it is the caller's.
(defstruct HttpBodyFeed
  (:lifetimes input)
  (consumed i64)
  (step (HttpBodyStep input)))

;: Result of delivering a terminal transport signal.
(defenum HttpBodyFinishResult
  (HttpBodyFinishComplete HttpBodyDecoder HttpBodyCompletion)
  (HttpBodyFinishErr HttpBodyDecoder HttpBodyDecodeError))

;: Conservative defaults: 64 KiB per step, no total cap, no scratch.
(define (default-body-decode-limits) : HttpBodyDecodeLimits
  (HttpBodyDecodeLimits 65536 (HttpBodyTotalUnlimited) 0))

;: Whether `limits` can be used: a positive step bound, a non-negative finite
;: total when one is given, and non-negative scratch.
(define (body-decode-limits-valid? [limits : (& limits HttpBodyDecodeLimits)]) : bool
  (and
    (> limits.max-step-bytes 0)
    (>= limits.max-scratch-bytes 0)
    (match limits.total
      [(HttpBodyTotalUnlimited) true]
      [(HttpBodyTotalAtMost cap) (>= cap 0)])))

(define (body-decode-error
  [kind : HttpBodyErrorKind]
  [mode : HttpBodyMode]
  [phase : HttpBodyPhase]
  [wire-consumed : i64]
  [decoded : i64]) : HttpBodyDecodeError
  (HttpBodyDecodeError kind mode phase wire-consumed decoded))

(define (body-completion
  [kind : HttpBodyCompletionKind]
  [wire-consumed : i64]
  [decoded : i64]) : HttpBodyCompletion
  (HttpBodyCompletion kind wire-consumed decoded (http_types.headers-empty)))

;: Largest representable i64.
(define (body-counter-max) : i64
  9223372036854775807)

;: Whether `count` more bytes fit both checked counters.
(define (body-counters-fit?
  [decoder : (& decoder HttpBodyDecoder)]
  [count : i64]) : bool
  (and
    (<= decoder.wire-consumed (- (body-counter-max) count))
    (<= decoder.decoded (- (body-counter-max) count))))

(define (body-decoder-with
  [decoder : HttpBodyDecoder]
  [wire-consumed : i64]
  [decoded : i64]
  [state : HttpBodyDecoderState]) : HttpBodyDecoder
  (HttpBodyDecoder
    decoder.mode
    decoder.transport
    decoder.limits
    wire-consumed
    decoded
    state))

(define (body-decoder-init-error
  [kind : HttpBodyErrorKind]
  [mode : HttpBodyMode]) : HttpBodyDecoderNewResult
  (HttpBodyDecoderNewErr (body-decode-error kind mode (HttpBodyPhaseInit) 0 0)))

(define (body-decoder-open
  [mode : HttpBodyMode]
  [transport : HttpBodyTransport]
  [limits : HttpBodyDecodeLimits]
  [state : HttpBodyDecoderState]) : HttpBodyDecoderNewResult
  (HttpBodyDecoderNewOk (HttpBodyDecoder mode transport limits 0 0 state)))

;: Start decoding a body from its response plan. Limits and the plan are
;: validated first; no-body plans (HEAD, 1xx, 204, 304, and an approved CONNECT
;: tunnel) and a zero fixed length start complete. A fixed length above a finite
;: total cap fails here, before any body byte. A chunked plan is rejected until
;: #7324 adds chunked framing; unsupported transfer codings always fail.
(define (body-decoder-new
  [plan : http_types.HttpResponseBodyPlan]
  [transport : HttpBodyTransport]
  [limits : HttpBodyDecodeLimits]) : HttpBodyDecoderNewResult
  (let
    [mode : HttpBodyMode
      (match plan
        [(http_types.HttpResponsePlanFixed _) (HttpBodyModeFixed)]
        [(http_types.HttpResponsePlanCloseDelimited)
          (HttpBodyModeCloseDelimited)]
        [(http_types.HttpResponsePlanChunked) (HttpBodyModeChunked)]
        [(http_types.HttpResponsePlanUnsupportedTransferCoding framing)
          (match framing
            [(http_types.HttpWireChunked) (HttpBodyModeChunked)]
            [(http_types.HttpWireCloseDelimited) (HttpBodyModeCloseDelimited)])]
        [(http_types.HttpResponsePlanNone) (HttpBodyModeNone)]
        [(http_types.HttpResponsePlanTunnel) (HttpBodyModeNone)])]
    (if (not (body-decode-limits-valid? (& limits)))
      (body-decoder-init-error (HttpBodyInvalidLimits) mode)
      (match plan
        [(http_types.HttpResponsePlanNone)
          (body-decoder-open
            mode
            transport
            limits
            (HttpBodyStateComplete (HttpBodyReuseEligible)))]
        [(http_types.HttpResponsePlanTunnel)
          (body-decoder-open
            mode
            transport
            limits
            (HttpBodyStateComplete (HttpBodyReuseEligible)))]
        [(http_types.HttpResponsePlanFixed length)
          (cond
            [(< length 0)
              (body-decoder-init-error (HttpBodyInvalidFixedLength) mode)]
            [(match limits.total
                [(HttpBodyTotalUnlimited) false]
                [(HttpBodyTotalAtMost cap) (> length cap)])
              (body-decoder-init-error (HttpBodyFixedLengthExceedsTotal) mode)]
            [(= length 0)
              (body-decoder-open
                mode
                transport
                limits
                (HttpBodyStateComplete (HttpBodyReuseEligible)))]
            [else
              (body-decoder-open
                mode
                transport
                limits
                (HttpBodyStateFixed length))])]
        [(http_types.HttpResponsePlanCloseDelimited)
          (body-decoder-open
            mode
            transport
            limits
            (HttpBodyStateCloseDelimited))]
        [(http_types.HttpResponsePlanChunked)
          (body-decoder-init-error (HttpBodyChunkedUnsupported) mode)]
        [(http_types.HttpResponsePlanUnsupportedTransferCoding framing)
          (body-decoder-init-error
            (HttpBodyUnsupportedTransferCoding framing)
            mode)]))))

(define (body-feed [consumed : i64] [step : (HttpBodyStep input)]) : (HttpBodyFeed
    input)
  (HttpBodyFeed consumed step))

(define (body-feed-failure
  [decoder : HttpBodyDecoder]
  [_input : (& input bytes)]
  [kind : HttpBodyErrorKind]) : (HttpBodyFeed input)
  (let
    [failure : HttpBodyDecodeError
      (body-decode-error
        kind
        decoder.mode
        (HttpBodyPhaseFeed)
        decoder.wire-consumed
        decoder.decoded)]
    (body-feed
      0
      (HttpBodyError
        (body-decoder-with
          (clone decoder)
          decoder.wire-consumed
          decoder.decoded
          (HttpBodyStateFailed (clone failure)))
        failure))))

;: Expose `count` bytes at the start of `input` as body data and advance the
;: counters; `next-state` is the state after them.
(define (body-feed-data
  [decoder : HttpBodyDecoder]
  [input : (& input bytes)]
  [count : i64]
  [next-state : HttpBodyDecoderState]) : (HttpBodyFeed input)
  (body-feed
    count
    (HttpBodyData
      (byte_buf.bytes-slice-view input 0 count)
      (body-decoder-with
        (clone decoder)
        (+ decoder.wire-consumed count)
        (+ decoder.decoded count)
        next-state))))

(define (body-min [left : i64] [right : i64]) : i64
  (if (< left right)
    left
    right))

;: Feed the next bytes of the stream. An open decoder given empty input returns
;: `NeedInput` unchanged; a complete or failed one consumes nothing and returns
;: its terminal outcome. Fixed framing returns at most the remaining declared
;: bytes and never touches the suffix. Close-delimited framing fails the whole
;: feed, consuming nothing, when the input holds more bytes than a finite total
;: still allows, and otherwise stays open until a terminal signal.
(define (body-decoder-feed
  [decoder : HttpBodyDecoder]
  [input : (& input bytes)]) : (HttpBodyFeed input)
  (let
    [input-len : i64 (byte_buf.bytes-length input)]
    [step-max : i64 decoder.limits.max-step-bytes]
    (match (clone decoder.state)
      [(HttpBodyStateFailed failure)
        (body-feed 0 (HttpBodyError decoder failure))]
      [(HttpBodyStateComplete kind)
        (body-feed
          0
          (HttpBodyComplete
            (clone decoder)
            (body-completion kind decoder.wire-consumed decoder.decoded)))]
      [(HttpBodyStateFixed remaining)
        (if (= input-len 0)
          (body-feed 0 (HttpBodyNeedInput decoder))
          (let
            [count : i64 (body-min (body-min input-len remaining) step-max)]
            (if (not (body-counters-fit? (& decoder) count))
              (body-feed-failure decoder input (HttpBodyCounterOverflow))
              (body-feed-data
                decoder
                input
                count
                (if (= count remaining)
                  (HttpBodyStateComplete (HttpBodyReuseEligible))
                  (HttpBodyStateFixed (- remaining count)))))))]
      [(HttpBodyStateCloseDelimited)
        (cond
          [(= input-len 0) (body-feed 0 (HttpBodyNeedInput decoder))]
          [(match decoder.limits.total
              [(HttpBodyTotalUnlimited) false]
              [(HttpBodyTotalAtMost cap) (> input-len (- cap decoder.decoded))])
            (body-feed-failure decoder input (HttpBodyTotalExceeded))]
          [else
            (let
              [count : i64 (body-min input-len step-max)]
              (if (not (body-counters-fit? (& decoder) count))
                (body-feed-failure decoder input (HttpBodyCounterOverflow))
                (body-feed-data
                  decoder
                  input
                  count
                  (HttpBodyStateCloseDelimited))))])])))

(define (body-finish-failure
  [decoder : HttpBodyDecoder]
  [kind : HttpBodyErrorKind]) : HttpBodyFinishResult
  (let
    [failure : HttpBodyDecodeError
      (body-decode-error
        kind
        decoder.mode
        (HttpBodyPhaseTerminal)
        decoder.wire-consumed
        decoder.decoded)]
    (HttpBodyFinishErr
      (body-decoder-with
        (clone decoder)
        decoder.wire-consumed
        decoder.decoded
        (HttpBodyStateFailed (clone failure)))
      failure)))

;: Whether `signal` can occur on `transport`: only TLS has a closure alert.
(define (body-signal-valid?
  [transport : HttpBodyTransport]
  [signal : HttpBodyTerminalSignal]) : bool
  (match signal
    [(HttpBodyTlsCloseNotify)
      (match transport
        [(HttpBodyTlsTransport) true]
        [(HttpBodyPlainTransport) false])]
    [(HttpBodyTlsAlert)
      (match transport
        [(HttpBodyTlsTransport) true]
        [(HttpBodyPlainTransport) false])]
    [_ true]))

;: Whether `signal` ends a close-delimited body on `transport`: an orderly EOF
;: on a plain stream, or the peer's authenticated `close_notify` on TLS.
(define (body-signal-closes?
  [transport : HttpBodyTransport]
  [signal : HttpBodyTerminalSignal]) : bool
  (match transport
    [(HttpBodyPlainTransport)
      (match signal
        [(HttpBodyOrderlyEof) true]
        [_ false])]
    [(HttpBodyTlsTransport)
      (match signal
        [(HttpBodyTlsCloseNotify) true]
        [_ false])]))

;: Deliver the transport's terminal signal. A complete body stays complete
;: whatever arrives later, and a failed one keeps its failure. An open fixed
;: body is incomplete under every signal. An open close-delimited body
;: completes, must-close, only on its transport's clean close; every other
;: signal leaves it incomplete. A signal the transport cannot produce is a
;: caller error.
(define (body-decoder-finish
  [decoder : HttpBodyDecoder]
  [signal : HttpBodyTerminalSignal]) : HttpBodyFinishResult
  (match (clone decoder.state)
    [(HttpBodyStateFailed failure) (HttpBodyFinishErr decoder failure)]
    [(HttpBodyStateComplete kind)
      (HttpBodyFinishComplete
        (clone decoder)
        (body-completion kind decoder.wire-consumed decoder.decoded))]
    [_
      (cond
        [(not (body-signal-valid? (clone decoder.transport) (clone signal)))
          (body-finish-failure decoder (HttpBodyInvalidTerminalSignal signal))]
        [(match (clone decoder.state)
            [(HttpBodyStateCloseDelimited)
              (body-signal-closes? (clone decoder.transport) (clone signal))]
            [_ false])
          (HttpBodyFinishComplete
            (body-decoder-with
              (clone decoder)
              decoder.wire-consumed
              decoder.decoded
              (HttpBodyStateComplete (HttpBodyMustClose)))
            (body-completion
              (HttpBodyMustClose)
              decoder.wire-consumed
              decoder.decoded))]
        [else (body-finish-failure decoder (HttpBodyIncomplete signal))])]))

;: The decoder's current disposition.
(define (body-decoder-disposition [decoder : (& decoder HttpBodyDecoder)]) : HttpBodyDisposition
  (match (clone decoder.state)
    [(HttpBodyStateFailed failure) (HttpBodyPoisonedIncomplete failure)]
    [(HttpBodyStateComplete (HttpBodyReuseEligible))
      (HttpBodyReuseEligibleComplete)]
    [(HttpBodyStateComplete (HttpBodyMustClose)) (HttpBodyMustCloseComplete)]
    [_ (HttpBodyOpen)]))