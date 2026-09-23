(import stdlib.byte_buf)
(import stdlib.net.http_body_decode as body)
(import stdlib.net.http_head_codec)
(import stdlib.net.http_types)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

;; --- limits, plans, decoders ---------------------------------------------------
(define (limits-with [step : i64] [total : body.HttpBodyTotalLimit]) : body.HttpBodyDecodeLimits
  (body.HttpBodyDecodeLimits step total 0))

(define (unlimited [step : i64]) : body.HttpBodyDecodeLimits
  (limits-with step (body.HttpBodyTotalUnlimited)))

(define (capped [step : i64] [cap : i64]) : body.HttpBodyDecodeLimits
  (limits-with step (body.HttpBodyTotalAtMost cap)))

(define (fixed-plan [length : i64]) : http_types.HttpResponseBodyPlan
  (http_types.HttpResponsePlanFixed length))

(define (close-plan) : http_types.HttpResponseBodyPlan
  (http_types.HttpResponsePlanCloseDelimited))

(define (plain) : body.HttpBodyTransport
  (body.HttpBodyPlainTransport))

(define (tls) : body.HttpBodyTransport
  (body.HttpBodyTlsTransport))

;; A decoder that cannot occur from `body-decoder-new`; returned after a
;; construction failure so the failing assertion is the one reported.
(define (fallback-decoder) : body.HttpBodyDecoder
  (body.HttpBodyDecoder
    (body.HttpBodyModeNone)
    (body.HttpBodyPlainTransport)
    (body.default-body-decode-limits)
    0
    0
    (body.HttpBodyStateComplete (body.HttpBodyReuseEligible))))

(define (new-decoder
  [plan : http_types.HttpResponseBodyPlan]
  [transport : body.HttpBodyTransport]
  [limits : body.HttpBodyDecodeLimits]) : body.HttpBodyDecoder
  (match (body.body-decoder-new plan transport limits)
    [(body.HttpBodyDecoderNewOk decoder) decoder]
    [(body.HttpBodyDecoderNewErr _)
      (begin
        (fail "valid decoder construction rejected")
        (fallback-decoder))]))

;; --- stable codes for comparing outcomes ---------------------------------------
(define (signal-code [signal : body.HttpBodyTerminalSignal]) : i64
  (match signal
    [(body.HttpBodyOrderlyEof) 0]
    [(body.HttpBodyTlsCloseNotify) 1]
    [(body.HttpBodyTlsAlert) 2]
    [(body.HttpBodyReset) 3]
    [(body.HttpBodyTimeout) 4]
    [(body.HttpBodyCancelled) 5]
    [(body.HttpBodyIoFailure) 6]))

(define (signal-of [code : i64]) : body.HttpBodyTerminalSignal
  (cond
    [(= code 0) (body.HttpBodyOrderlyEof)]
    [(= code 1) (body.HttpBodyTlsCloseNotify)]
    [(= code 2) (body.HttpBodyTlsAlert)]
    [(= code 3) (body.HttpBodyReset)]
    [(= code 4) (body.HttpBodyTimeout)]
    [(= code 5) (body.HttpBodyCancelled)]
    [else (body.HttpBodyIoFailure)]))

(define (signal-count) : i64
  7)

;; Error kinds: 10 invalid limits, 11 invalid fixed length, 12/13 unsupported
;; coding over chunked/close wire, 14 chunked unsupported, 15 fixed over total,
;; 16 total exceeded, 17 counter overflow, 100+s invalid signal s, 200+s
;; incomplete under signal s.
(define (error-code [kind : body.HttpBodyErrorKind]) : i64
  (match kind
    [(body.HttpBodyInvalidLimits) 10]
    [(body.HttpBodyInvalidFixedLength) 11]
    [(body.HttpBodyUnsupportedTransferCoding framing)
      (match framing
        [(http_types.HttpWireChunked) 12]
        [(http_types.HttpWireCloseDelimited) 13])]
    [(body.HttpBodyChunkedUnsupported) 14]
    [(body.HttpBodyFixedLengthExceedsTotal) 15]
    [(body.HttpBodyTotalExceeded) 16]
    [(body.HttpBodyCounterOverflow) 17]
    [(body.HttpBodyInvalidTerminalSignal signal) (+ 100 (signal-code signal))]
    [(body.HttpBodyIncomplete signal) (+ 200 (signal-code signal))]))

(define (mode-code [mode : body.HttpBodyMode]) : i64
  (match mode
    [(body.HttpBodyModeNone) 0]
    [(body.HttpBodyModeFixed) 1]
    [(body.HttpBodyModeCloseDelimited) 2]
    [(body.HttpBodyModeChunked) 3]))

(define (phase-code [phase : body.HttpBodyPhase]) : i64
  (match phase
    [(body.HttpBodyPhaseInit) 0]
    [(body.HttpBodyPhaseFeed) 1]
    [(body.HttpBodyPhaseTerminal) 2]))

;; Dispositions: 0 open, 1 reuse-eligible complete, 2 must-close complete,
;; 3 poisoned incomplete.
(define (disposition-code [decoder : (& decoder body.HttpBodyDecoder)]) : i64
  (match (body.body-decoder-disposition decoder)
    [(body.HttpBodyOpen) 0]
    [(body.HttpBodyReuseEligibleComplete) 1]
    [(body.HttpBodyMustCloseComplete) 2]
    [(body.HttpBodyPoisonedIncomplete _) 3]))

(define (completion-code [completion : (& completion body.HttpBodyCompletion)]) : i64
  (match completion.kind
    [(body.HttpBodyReuseEligible) 1]
    [(body.HttpBodyMustClose) 2]))

;; --- a driver that records everything a feed sequence observes ----------------
;; `data` concatenates every returned view; `suffix` is the input the body left
;; unconsumed once it reached a terminal state. `outcome` is the disposition
;; code at the end, `error` the error code or -1, `max-step` the largest view.
(defstruct Run
  (data byte_buf.ByteBuf)
  (suffix byte_buf.ByteBuf)
  (outcome i64)
  (error i64)
  (wire i64)
  (decoded i64)
  (trailers i64)
  (max-step i64)
  (steps i64))

(define (run-empty) : Run
  (Run (byte_buf.new) (byte_buf.new) 0 -1 0 0 -1 0 0))

(define (record-completion [run : Run] [completion : body.HttpBodyCompletion]) : Run
  (Run
    run.data
    run.suffix
    (completion-code (& completion))
    -1
    completion.wire-consumed
    completion.decoded
    (http_types.headers-len (& completion.trailers))
    run.max-step
    run.steps))

(define (record-error [run : Run] [failure : body.HttpBodyDecodeError]) : Run
  (Run
    run.data
    run.suffix
    3
    (error-code (clone failure.kind))
    failure.wire-consumed
    failure.decoded
    -1
    run.max-step
    run.steps))

;; Feed `wire` to `decoder` in consecutive parts of the given lengths, then,
;; unless the body already ended, deliver terminal `signal` (a code, or -1 for
;; none). Once the body ends, the rest of the wire is its suffix.
(define (drive
  [start : body.HttpBodyDecoder]
  [wire : String]
  [parts : (__tl_dyn-array i64)]
  [part-count : i64]
  [signal : i64]) : Run
  (let
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [total : i64 (byte_buf.bytes-length view)]
    [decoder : body.HttpBodyDecoder start]
    [run : Run (run-empty)]
    [pos : i64 0]
    [part : i64 0]
    [ended : bool false]
    (begin
      (while (and (not ended) (< part part-count))
        (let
          [len : i64 (array-ref parts part)]
          [off : i64 0]
          [chunk-done : bool false]
          (begin
            (while (and (not ended) (not chunk-done))
              (let
                [fed : (body.HttpBodyFeed wire)
                  (body.body-decoder-feed
                    (clone decoder)
                    (byte_buf.bytes-slice-view view (+ pos off) (- len off)))]
                (begin
                  (set! off (+ off fed.consumed))
                  (match fed.step
                    [(body.HttpBodyData data next)
                      (begin
                        (set! run.data (byte_buf.append-bytes run.data data))
                        (if (> (byte_buf.bytes-length data) run.max-step)
                          (set! run.max-step (byte_buf.bytes-length data))
                          unit)
                        (set! run.steps (+ run.steps 1))
                        (set! decoder next)
                        (if (= off len)
                          (set! chunk-done true)
                          unit))]
                    [(body.HttpBodyNeedInput next)
                      (begin
                        (set! decoder next)
                        (set! chunk-done true))]
                    [(body.HttpBodyComplete next completion)
                      (begin
                        (set! decoder next)
                        (set! run (record-completion run completion))
                        (set! ended true))]
                    [(body.HttpBodyError next failure)
                      (begin
                        (set! decoder next)
                        (set! run (record-error run failure))
                        (set! ended true))]))))
            (if ended
              (set!
                run.suffix
                (byte_buf.from-bytes-range
                  view
                  (+ pos off)
                  (- total (+ pos off))))
              unit)
            (set! pos (+ pos len))
            (set! part (+ part 1)))))
      (if (and (not ended) (>= signal 0))
        (match (body.body-decoder-finish (clone decoder) (signal-of signal))
          [(body.HttpBodyFinishComplete _ completion)
            (set! run (record-completion run completion))]
          [(body.HttpBodyFinishErr _ failure)
            (set! run (record-error run failure))])
        (if (not ended)
          (begin
            (set! run.outcome (disposition-code (& decoder)))
            (set! run.wire decoder.wire-consumed)
            (set! run.decoded decoder.decoded))
          unit))
      run)))

(define (one-part [length : i64]) : (__tl_dyn-array i64)
  (__tl_make-array length))

(define (drive-whole
  [decoder : body.HttpBodyDecoder]
  [wire : String]
  [signal : i64]) : Run
  (drive decoder (clone wire) (one-part (string.string-length wire)) 1 signal))

(define (buf-eq? [buf : (& buf byte_buf.ByteBuf)] [expected : String]) : bool
  (string.eq (byte_buf.bytes-to-string (byte_buf.as-bytes buf)) expected))

(define (assert-run
  [run : (& run Run)]
  [data : String]
  [suffix : String]
  [outcome : i64]
  [error : i64]
  [message : String]) : unit
  (begin
    (test.assert-true
      (buf-eq? (& run.data) (clone data))
      (labeled (& message) " data"))
    (test.assert-true
      (buf-eq? (& run.suffix) suffix)
      (labeled (& message) " suffix"))
    (test.assert-i64-eq outcome run.outcome (labeled (& message) " outcome"))
    (test.assert-i64-eq error run.error (labeled (& message) " error"))
    (test.assert-i64-eq
      (string.string-length data)
      run.decoded
      (labeled (& message) " decoded"))
    (test.assert-i64-eq run.decoded run.wire (labeled (& message) " wire"))
    (if (or (= outcome 1) (= outcome 2))
      (test.assert-i64-eq 0 run.trailers (labeled (& message) " trailers"))
      unit)))

(define (labeled [label : (& label str)] [detail : String]) : String
  (str_cat.str-cat (string.copy label) detail))

(define (repeat-text [text : String] [times : i64]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    (begin
      (while (< index times)
        (begin
          (set! buf (byte_buf.append-string buf (clone text)))
          (set! index (+ index 1))))
      (byte_buf.to-string buf))))

;; --- no-body and fixed framing -------------------------------------------------
(define (assert-no-body-plans) : unit
  (let
    [plans : (__tl_dyn-array http_types.HttpResponseBodyPlan)
      (__tl_make-array http_types.HttpResponseBodyPlan 2)]
    [index : i64 0]
    (begin
      (set! (array-ref plans 0) (http_types.HttpResponsePlanNone))
      (set! (array-ref plans 1) (http_types.HttpResponsePlanTunnel))
      (while (< index 2)
        (let
          [decoder : body.HttpBodyDecoder
            (new-decoder (clone (array-ref plans index)) (plain) (unlimited 4))]
          [run : Run (drive-whole (clone decoder) "HTTP/1.1 200 OK\r\n" -1)]
          [empty : String ""]
          (begin
            (assert-run
              (& run)
              ""
              "HTTP/1.1 200 OK\r\n"
              1
              -1
              "no-body leaves the whole input")
            (test.assert-i64-eq 0 run.steps "no-body returns no data")
            ;; An empty feed on a complete body is complete, never NeedInput.
            (match (body.body-decoder-feed
              (clone decoder)
              (byte_buf.str-as-bytes (& empty))).step
              [(body.HttpBodyComplete _ completion)
                (test.assert-i64-eq
                  0
                  completion.decoded
                  "no-body empty feed completes")]
              [_ (fail "no-body empty feed must stay complete")])
            (set! index (+ index 1)))))
      ;; The same holds for a zero fixed length.
      (let
        [run : Run
          (drive-whole
            (new-decoder (fixed-plan 0) (plain) (unlimited 4))
            "NEXT"
            -1)]
        (assert-run (& run) "" "NEXT" 1 -1 "zero fixed length")))))

(define (assert-fixed-lengths) : unit
  (begin
    (let
      [run : Run
        (drive-whole
          (new-decoder (fixed-plan 1) (plain) (unlimited 8))
          "xYZ"
          -1)]
      (begin
        (assert-run (& run) "x" "YZ" 1 -1 "fixed one byte")
        (test.assert-i64-eq 1 run.steps "fixed one byte in one step")))
    ;; Exact completion in the data-returning step: the Data result's next
    ;; decoder is already complete and reuse eligible.
    (let
      [wire : String "helloNEXT"]
      [fed : (body.HttpBodyFeed wire)
        (body.body-decoder-feed
          (new-decoder (fixed-plan 5) (plain) (unlimited 64))
          (byte_buf.str-as-bytes (& wire)))]
      (begin
        (test.assert-i64-eq 5 fed.consumed "fixed consumes the declared bytes")
        (match fed.step
          [(body.HttpBodyData data next)
            (begin
              (test.assert-i64-eq 5 (byte_buf.bytes-length data) "fixed view")
              (test.assert-i64-eq
                1
                (disposition-code (& next))
                "final fixed view completes the body"))]
          [_ (fail "fixed body must return data")])))
    ;; A large body in bounded steps.
    (let
      [large : String (repeat-text "0123456789" 100)]
      [run : Run
        (drive-whole
          (new-decoder (fixed-plan 1000) (plain) (unlimited 64))
          (str_cat.str-cat (clone large) "TAIL")
          -1)]
      (begin
        (assert-run (& run) (clone large) "TAIL" 1 -1 "large fixed")
        (test.assert-i64-eq 64 run.max-step "large fixed step bound")
        (test.assert-i64-eq 16 run.steps "large fixed step count")))
    ;; An empty feed on an open fixed body is NeedInput with nothing changed.
    (let
      [empty : String ""]
      [fed : (body.HttpBodyFeed empty)
        (body.body-decoder-feed
          (new-decoder (fixed-plan 3) (plain) (unlimited 8))
          (byte_buf.str-as-bytes (& empty)))]
      (match fed.step
        [(body.HttpBodyNeedInput next)
          (begin
            (test.assert-i64-eq
              0
              fed.consumed
              "empty fixed feed consumes nothing")
            (test.assert-i64-eq
              0
              next.decoded
              "empty fixed feed keeps counters")
            (test.assert-i64-eq 0 (disposition-code (& next)) "still open"))]
        [_ (fail "empty open fixed feed must be NeedInput")]))))

;; Fixed completion survives every later terminal signal; the same signals
;; before completion leave the body incomplete.
(define (assert-fixed-terminals) : unit
  (let
    [signal : i64 0]
    (while (< signal (signal-count))
      (begin
        (let
          [after : Run
            (drive-whole
              (new-decoder (fixed-plan 3) (tls) (unlimited 8))
              "abc"
              signal)]
          (assert-run (& after) "abc" "" 1 -1 "fixed complete before signal"))
        (let
          [finished : body.HttpBodyFinishResult
            (body.body-decoder-finish
              (new-decoder (fixed-plan 0) (plain) (unlimited 8))
              (signal-of signal))]
          (match finished
            [(body.HttpBodyFinishComplete next completion)
              (begin
                (test.assert-i64-eq
                  1
                  (completion-code (& completion))
                  "late signal keeps a complete body")
                (test.assert-i64-eq
                  1
                  (disposition-code (& next))
                  "still reusable"))]
            [(body.HttpBodyFinishErr _ _)
              (fail "a signal after completion must not fail the body")]))
        (let
          [before : Run
            (drive-whole
              (new-decoder (fixed-plan 5) (tls) (unlimited 8))
              "abc"
              signal)]
          (assert-run
            (& before)
            "abc"
            ""
            3
            (+ 200 signal)
            "fixed signal before completion"))
        (set! signal (+ signal 1))))))

;; --- close-delimited framing ---------------------------------------------------
(define (close-outcome [transport : body.HttpBodyTransport] [signal : i64]) : Run
  (drive-whole
    (new-decoder (close-plan) transport (unlimited 4))
    "abcdef"
    signal))

(define (assert-close-delimited) : unit
  (let
    [plain-eof : Run (close-outcome (plain) 0)]
    [tls-close : Run (close-outcome (tls) 1)]
    [tls-eof : Run (close-outcome (tls) 0)]
    [tls-alert : Run (close-outcome (tls) 2)]
    [plain-notify : Run (close-outcome (plain) 1)]
    [plain-alert : Run (close-outcome (plain) 2)]
    [signal : i64 3]
    (begin
      (assert-run (& plain-eof) "abcdef" "" 2 -1 "plain orderly EOF closes")
      (test.assert-i64-eq 4 plain-eof.max-step "close step bound")
      (assert-run (& tls-close) "abcdef" "" 2 -1 "TLS close_notify closes")
      (assert-run (& tls-eof) "abcdef" "" 3 200 "TLS EOF without close_notify")
      (assert-run (& tls-alert) "abcdef" "" 3 202 "TLS alert")
      (assert-run
        (& plain-notify)
        "abcdef"
        ""
        3
        101
        "plain close_notify is invalid")
      (assert-run
        (& plain-alert)
        "abcdef"
        ""
        3
        102
        "plain TLS alert is invalid")
      (while (< signal (signal-count))
        (begin
          (let
            [on-plain : Run (close-outcome (plain) signal)]
            [on-tls : Run (close-outcome (tls) signal)]
            (begin
              (assert-run
                (& on-plain)
                "abcdef"
                ""
                3
                (+ 200 signal)
                "plain failure signal")
              (assert-run
                (& on-tls)
                "abcdef"
                ""
                3
                (+ 200 signal)
                "TLS failure signal")))
          (set! signal (+ signal 1))))
      ;; After a close completes, feeds and signals repeat the completion.
      (match (body.body-decoder-finish
        (new-decoder (close-plan) (plain) (unlimited 4))
        (body.HttpBodyOrderlyEof))
        [(body.HttpBodyFinishComplete done _)
          (let
            [more : String "zz"]
            [fed : (body.HttpBodyFeed more)
              (body.body-decoder-feed
                (clone done)
                (byte_buf.str-as-bytes (& more)))]
            (begin
              (test.assert-i64-eq
                0
                fed.consumed
                "complete close consumes nothing")
              (match fed.step
                [(body.HttpBodyComplete _ completion)
                  (test.assert-i64-eq
                    2
                    (completion-code (& completion))
                    "complete close stays must-close")]
                [_ (fail "complete close feed must repeat completion")])
              (match (body.body-decoder-finish done (body.HttpBodyReset))
                [(body.HttpBodyFinishComplete _ _) unit]
                [(body.HttpBodyFinishErr _ _)
                  (fail "reset after close must not fail the body")])))]
        [(body.HttpBodyFinishErr _ _)
          (fail "orderly EOF must close an empty body")]))))

;; --- limits, atomicity, and counters -------------------------------------------
(define (assert-init-error
  [plan : http_types.HttpResponseBodyPlan]
  [limits : body.HttpBodyDecodeLimits]
  [expected : i64]
  [mode : i64]
  [message : String]) : unit
  (match (body.body-decoder-new plan (plain) limits)
    [(body.HttpBodyDecoderNewErr failure)
      (begin
        (test.assert-i64-eq
          (error-code (clone failure.kind))
          expected
          (clone message))
        (test.assert-i64-eq
          (mode-code (clone failure.mode))
          mode
          (clone message))
        (test.assert-i64-eq
          (phase-code (clone failure.phase))
          0
          (clone message))
        (test.assert-i64-eq failure.wire-consumed 0 (clone message))
        (test.assert-i64-eq failure.decoded 0 message))]
    [(body.HttpBodyDecoderNewOk _) (fail message)]))

(define (assert-limits) : unit
  (begin
    (assert-init-error (fixed-plan 3) (unlimited 0) 10 1 "zero step bound")
    (assert-init-error (fixed-plan 3) (unlimited -1) 10 1 "negative step bound")
    (assert-init-error (close-plan) (capped 4 -1) 10 2 "negative total cap")
    (assert-init-error
      (fixed-plan 3)
      (body.HttpBodyDecodeLimits 4 (body.HttpBodyTotalUnlimited) -1)
      10
      1
      "negative scratch bound")
    (assert-init-error
      (fixed-plan -1)
      (unlimited 4)
      11
      1
      "negative fixed length")
    (assert-init-error (fixed-plan 6) (capped 4 5) 15 1 "fixed length over cap")
    (let
      [at-cap : Run
        (drive-whole
          (new-decoder (fixed-plan 5) (plain) (capped 2 5))
          "helloX"
          -1)]
      (assert-run (& at-cap) "hello" "X" 1 -1 "fixed length equal to cap"))
    ;; Close-delimited: an input larger than the remaining allowance fails the
    ;; whole feed without consuming or exposing anything.
    (let
      [over : Run
        (drive-whole (new-decoder (close-plan) (plain) (capped 8 5)) "abcdef" 0)]
      (begin
        (assert-run (& over) "" "abcdef" 3 16 "close input over cap")
        (test.assert-i64-eq 0 over.steps "over-cap feed exposes nothing")))
    (let
      [second-over : Run
        (drive
          (new-decoder (close-plan) (plain) (capped 8 5))
          "abcdef"
          (__tl_make-array 3 3)
          2
          0)]
      (assert-run (& second-over) "abc" "def" 3 16 "second feed over cap"))
    (let
      [exact : Run
        (drive-whole (new-decoder (close-plan) (plain) (capped 8 5)) "abcde" 0)]
      (assert-run (& exact) "abcde" "" 2 -1 "exact cap then close"))
    (let
      [one-more : Run
        (drive
          (new-decoder (close-plan) (plain) (capped 8 5))
          "abcdeX"
          (__tl_make-array 5 1)
          2
          0)]
      (begin
        (assert-run (& one-more) "abcde" "X" 3 16 "byte after exact cap")
        (test.assert-i64-eq 1 one-more.steps "byte after cap is not exposed")))
    ;; Checked counters: an overflowing step fails before any view exists.
    (let
      [near-max : i64 (- (body.body-counter-max) 2)]
      [close-near : body.HttpBodyDecoder
        (body.HttpBodyDecoder
          (body.HttpBodyModeCloseDelimited)
          (body.HttpBodyPlainTransport)
          (unlimited 16)
          near-max
          near-max
          (body.HttpBodyStateCloseDelimited))]
      [fixed-near : body.HttpBodyDecoder
        (body.HttpBodyDecoder
          (body.HttpBodyModeFixed)
          (body.HttpBodyPlainTransport)
          (unlimited 16)
          near-max
          near-max
          (body.HttpBodyStateFixed 10))]
      [wire : String "abcd"]
      (begin
        (let
          [fed : (body.HttpBodyFeed wire)
            (body.body-decoder-feed close-near (byte_buf.str-as-bytes (& wire)))]
          (begin
            (test.assert-i64-eq 0 fed.consumed "overflow consumes nothing")
            (match fed.step
              [(body.HttpBodyError _ failure)
                (test.assert-i64-eq
                  17
                  (error-code (clone failure.kind))
                  "close counter overflow")]
              [_ (fail "close counter overflow must fail")])))
        (let
          [fed : (body.HttpBodyFeed wire)
            (body.body-decoder-feed fixed-near (byte_buf.str-as-bytes (& wire)))]
          (match fed.step
            [(body.HttpBodyError _ failure)
              (test.assert-i64-eq
                17
                (error-code (clone failure.kind))
                "fixed counter overflow")]
            [_ (fail "fixed counter overflow must fail")]))
        (let
          [two : String "ab"]
          [fed : (body.HttpBodyFeed two)
            (body.body-decoder-feed
              (body.HttpBodyDecoder
                (body.HttpBodyModeCloseDelimited)
                (body.HttpBodyPlainTransport)
                (unlimited 16)
                near-max
                near-max
                (body.HttpBodyStateCloseDelimited))
              (byte_buf.str-as-bytes (& two)))]
          (match fed.step
            [(body.HttpBodyData _ next)
              (test.assert-i64-eq
                (body.body-counter-max)
                next.decoded
                "a step reaching the counter maximum is allowed")]
            [_ (fail "a non-overflowing step must return data")]))))
    ;; A failed decoder repeats its failure and consumes nothing.
    (let
      [wire : String "abcdef"]
      [first : (body.HttpBodyFeed wire)
        (body.body-decoder-feed
          (new-decoder (close-plan) (plain) (capped 8 2))
          (byte_buf.str-as-bytes (& wire)))]
      (match first.step
        [(body.HttpBodyError failed failure)
          (let
            [again : (body.HttpBodyFeed wire)
              (body.body-decoder-feed
                (clone failed)
                (byte_buf.str-as-bytes (& wire)))]
            (begin
              (test.assert-i64-eq
                0
                again.consumed
                "failed feed consumes nothing")
              (match again.step
                [(body.HttpBodyError _ repeated)
                  (test.assert-i64-eq
                    (error-code (clone failure.kind))
                    (error-code (clone repeated.kind))
                    "failed feed repeats its failure")]
                [_ (fail "failed decoder must stay failed")])
              (match (body.body-decoder-finish failed (body.HttpBodyOrderlyEof))
                [(body.HttpBodyFinishErr _ repeated)
                  (test.assert-i64-eq
                    16
                    (error-code (clone repeated.kind))
                    "failed finish repeats its failure")]
                [_ (fail "failed decoder must not complete")])))]
        [_ (fail "over-cap close feed must fail")]))))

;; --- plans that this decoder does not decode -----------------------------------
(define (assert-unsupported-plans) : unit
  (begin
    (assert-init-error
      (http_types.HttpResponsePlanChunked)
      (unlimited 4)
      14
      3
      "chunked is rejected until #7324")
    (assert-init-error
      (http_types.HttpResponsePlanUnsupportedTransferCoding
        (http_types.HttpWireChunked))
      (unlimited 4)
      12
      3
      "unsupported coding over chunked wire")
    (assert-init-error
      (http_types.HttpResponsePlanUnsupportedTransferCoding
        (http_types.HttpWireCloseDelimited))
      (unlimited 4)
      13
      2
      "unsupported coding over close wire")))

;; --- every partition gives the same result -------------------------------------
;; Feed `wire` under every partition into consecutive parts and every step
;; bound in 1..4, and require the single-part result each time.
(define (assert-partitions
  [plan : http_types.HttpResponseBodyPlan]
  [transport : body.HttpBodyTransport]
  [wire : String]
  [signal : i64]
  [data : String]
  [suffix : String]
  [outcome : i64]
  [error : i64]
  [message : String]) : unit
  (let
    [n : i64 (string.string-length wire)]
    [masks : i64 (shl 1 (- n 1))]
    [step : i64 1]
    (while (<= step 4)
      (let
        [mask : i64 0]
        (begin
          (while (< mask masks)
            (let
              [parts : (__tl_dyn-array i64) (__tl_make-array i64 n)]
              [count : i64 0]
              [start : i64 0]
              [cut : i64 1]
              (begin
                (while (< cut n)
                  (begin
                    (if (!= (bit-and mask (shl 1 (- cut 1))) 0)
                      (begin
                        (set! (array-ref parts count) (- cut start))
                        (set! count (+ count 1))
                        (set! start cut))
                      unit)
                    (set! cut (+ cut 1))))
                (set! (array-ref parts count) (- n start))
                (set! count (+ count 1))
                (let
                  [run : Run
                    (drive
                      (new-decoder
                        (clone plan)
                        (clone transport)
                        (unlimited step))
                      (clone wire)
                      parts
                      count
                      signal)]
                  (assert-run
                    (& run)
                    (clone data)
                    (clone suffix)
                    outcome
                    error
                    (clone message)))
                (set! mask (+ mask 1)))))
          (set! step (+ step 1)))))))

(define (assert-every-partition) : unit
  (begin
    (assert-partitions
      (fixed-plan 5)
      (plain)
      "helloNEXT"
      0
      "hello"
      "NEXT"
      1
      -1
      "fixed")
    (assert-partitions
      (http_types.HttpResponsePlanNone)
      (plain)
      "NEXT"
      0
      ""
      "NEXT"
      1
      -1
      "no-body")
    (assert-partitions
      (close-plan)
      (plain)
      "abcdefgh"
      0
      "abcdefgh"
      ""
      2
      -1
      "close")
    (assert-partitions
      (close-plan)
      (tls)
      "abcdefgh"
      0
      "abcdefgh"
      ""
      3
      200
      "TLS EOF")
    (assert-partitions
      (fixed-plan 9)
      (plain)
      "abcdefgh"
      3
      "abcdefgh"
      ""
      3
      203
      "short")))

;; --- plans from real response heads --------------------------------------------
;; Parse the response head at the start of `wire` for `method`, then decode the
;; body from the rest of the same wire.
(define (decode-response
  [wire : String]
  [method : http_types.HttpResponseRequestMethod]
  [capability : http_types.HttpConnectCapability]
  [signal : i64]) : Run
  (let
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    (match (http_head_codec.response-parser-new
      (http_types.default-head-limits)
      method
      capability)
      [(http_head_codec.HttpResponseParserNewErr _)
        (begin
          (fail "response parser construction")
          (run-empty))]
      [(http_head_codec.HttpResponseParserNewOk parser)
        (match (http_head_codec.response-parser-feed parser view)
          [(http_head_codec.HttpResponseFeedComplete head consumed)
            (drive-whole
              (new-decoder (clone head.body-plan) (plain) (unlimited 1024))
              (byte_buf.bytes-to-string
                (byte_buf.bytes-slice-view
                  view
                  consumed
                  (- (byte_buf.bytes-length view) consumed)))
              signal)]
          [_
            (begin
              (fail "response head must parse")
              (run-empty))])])))

(define (assert-response-plans) : unit
  (let
    [fixed : Run
      (decode-response
        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhelloHTTP/1.1"
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied)
        -1)]
    [head : Run
      (decode-response
        "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\nNEXT"
        (http_types.HttpResponseToHead)
        (http_types.HttpConnectDenied)
        -1)]
    [early : Run
      (decode-response
        "HTTP/1.1 103 Early Hints\r\n\r\nHTTP/1.1 200 OK\r\n"
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied)
        -1)]
    [no-content : Run
      (decode-response
        "HTTP/1.1 204 No Content\r\nContent-Length: 7\r\n\r\nNEXT"
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied)
        -1)]
    [not-modified : Run
      (decode-response
        "HTTP/1.1 304 Not Modified\r\n\r\nNEXT"
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied)
        -1)]
    [tunnel : Run
      (decode-response
        "HTTP/1.1 200 Connection Established\r\n\r\nTUNNEL-BYTES"
        (http_types.HttpResponseToConnect)
        (http_types.HttpConnectAuthorized)
        -1)]
    [until-close : Run
      (decode-response
        "HTTP/1.1 200 OK\r\n\r\nstream"
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied)
        0)]
    (begin
      (assert-run (& fixed) "hello" "HTTP/1.1" 1 -1 "fixed response")
      (assert-run (& head) "" "NEXT" 1 -1 "HEAD response")
      (assert-run (& early) "" "HTTP/1.1 200 OK\r\n" 1 -1 "1xx response")
      (assert-run (& no-content) "" "NEXT" 1 -1 "204 response")
      (assert-run (& not-modified) "" "NEXT" 1 -1 "304 response")
      (assert-run (& tunnel) "" "TUNNEL-BYTES" 1 -1 "CONNECT tunnel")
      (assert-run (& until-close) "stream" "" 2 -1 "close-delimited response"))))

;; A view is used within its input's lifetime. Once it is dead the owning
;; buffer may be advanced past the consumed prefix and fed again; the three
;; `http_body_decode_view_*_reject` fixtures cover the forbidden shapes.
(define (assert-owner-advance) : unit
  (let
    [wire : byte_buf.ByteBuf (byte_buf.from-string "helloNEXT")]
    [decoder : body.HttpBodyDecoder
      (new-decoder (fixed-plan 7) (plain) (unlimited 3))]
    [seen : byte_buf.ByteBuf (byte_buf.new)]
    [feeds : i64 0]
    [done : bool false]
    (begin
      (while (and (not done) (< feeds 10))
        (let
          [consumed : i64
            (let
              [fed : (body.HttpBodyFeed wire)
                (body.body-decoder-feed
                  (clone decoder)
                  (byte_buf.as-bytes (& wire)))]
              (match fed.step
                [(body.HttpBodyData view next)
                  (begin
                    (set! seen (byte_buf.append-bytes seen view))
                    (set! decoder next)
                    fed.consumed)]
                [(body.HttpBodyComplete next _)
                  (begin
                    (set! decoder next)
                    (set! done true)
                    fed.consumed)]
                [_
                  (begin
                    (fail "owner advance must not need input or fail")
                    (set! done true)
                    0)]))]
          [rest : byte_buf.ByteBuf
            (byte_buf.from-bytes-range
              (byte_buf.as-bytes (& wire))
              consumed
              (- (byte_buf.len (& wire)) consumed))]
          (begin
            (set! wire rest)
            (set! feeds (+ feeds 1)))))
      (test.assert-true (buf-eq? (& seen) "helloNE") "advanced body data")
      (test.assert-true (buf-eq? (& wire) "XT") "advanced suffix")
      (test.assert-i64-eq feeds 4 "three views and one completion"))))

(define (main) : i64
  (begin
    (assert-no-body-plans)
    (assert-fixed-lengths)
    (assert-fixed-terminals)
    (assert-close-delimited)
    (assert-limits)
    (assert-unsupported-plans)
    (assert-every-partition)
    (assert-response-plans)
    (assert-owner-advance)
    42))