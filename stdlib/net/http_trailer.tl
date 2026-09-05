;# Bounded incremental HTTP/1.1 response trailer parsing.
;#
;# The parser consumes exactly one trailer section after a terminal zero chunk.
;# It retains approved fields separately in wire order, never merges them into
;# the response head, and leaves every same-buffer suffix untouched. Completed
;# lines are parsed once; only the current line is kept as wire scratch.
;#
;# Usage: `(import stdlib.net.http_trailer)`.
(import stdlib.byte_buf)
(import stdlib.net.http_trailer_policy)
(import stdlib.net.http_types)

;: Independent wire and retained-storage bounds for one trailer section.
(defstruct HttpResponseTrailerLimits
  (max-total-bytes i64)
  (max-line-bytes i64)
  (max-fields i64)
  (max-name-bytes i64)
  (max-value-bytes i64)
  (max-retained-bytes i64))

;: Stable parser, syntax, policy, and resource failure categories.
(defenum HttpResponseTrailerErrorKind
  (HttpResponseTrailerInvalidLimits)
  (HttpResponseTrailerCorruptPolicy)
  (HttpResponseTrailerInvalidDeclaredNames)
  (HttpResponseTrailerSectionTooLarge)
  (HttpResponseTrailerRetainedBytesExceeded)
  (HttpResponseTrailerFieldError http_types.HttpHeadErrorKind)
  (HttpResponseTrailerPolicyError http_trailer_policy.HttpTrailerErrorKind)
  (HttpResponseTrailerTruncatedField)
  (HttpResponseTrailerTruncatedTerminator)
  (HttpResponseTrailerIncompleteResult))

;: First stable failing field and byte offset. Peer failures poison the
;: connection; invalid local construction/result use does not.
(defstruct HttpResponseTrailerError
  (kind HttpResponseTrailerErrorKind)
  (field-index i64)
  (offset i64)
  (poison-connection bool))

;: Terminal state is retained so later feeds consume zero and reproduce it.
(defenum HttpResponseTrailerParserState
  (HttpResponseTrailerOpen)
  (HttpResponseTrailerComplete)
  (HttpResponseTrailerFailed HttpResponseTrailerError))

;: Incremental parser owning its reusable current-line scratch and approved
;: field collection. `total-bytes` is relative to the trailer-section start.
(defstruct HttpResponseTrailerParser
  (line byte_buf.ByteBuf)
  (line-start i64)
  (saw-cr bool)
  (total-bytes i64)
  (retained-bytes i64)
  (fields http_types.HttpHeaders)
  (declared http_types.HttpHeaderNameSet)
  (policy http_trailer_policy.HttpTrailerPolicy)
  (limits HttpResponseTrailerLimits)
  (state HttpResponseTrailerParserState))

;: Recoverable construction result. Invalid local policy/limits consume no
;: input and are never connection-poisoning.
(defenum HttpResponseTrailerParserNewResult
  (HttpResponseTrailerParserNewOk HttpResponseTrailerParser)
  (HttpResponseTrailerParserNewErr HttpResponseTrailerError))

;: One feed result. `consumed` is relative to this call. Complete and Err keep
;: the terminal parser so a later feed can deterministically consume zero.
(defenum HttpResponseTrailerFeedResult
  (HttpResponseTrailerFeedNeedInput HttpResponseTrailerParser i64)
  (HttpResponseTrailerFeedComplete HttpResponseTrailerParser i64)
  (HttpResponseTrailerFeedErr
    HttpResponseTrailerParser
    HttpResponseTrailerError
    i64))

;: Explicit EOF result for an open or terminal parser.
(defenum HttpResponseTrailerFinishResult
  (HttpResponseTrailerFinishComplete HttpResponseTrailerParser)
  (HttpResponseTrailerFinishErr
    HttpResponseTrailerParser
    HttpResponseTrailerError))

;: Consuming extraction of the separately retained trailer fields.
(defenum HttpResponseTrailerFieldsResult
  (HttpResponseTrailerFieldsOk http_types.HttpHeaders)
  (HttpResponseTrailerFieldsErr HttpResponseTrailerError))

;: Internal result after one line receives its CRLF.
(defenum HttpResponseTrailerLineResult
  (HttpResponseTrailerLineContinue)
  (HttpResponseTrailerLineComplete)
  (HttpResponseTrailerLineErr HttpResponseTrailerError))

;: Conservative defaults matching ordinary response-head limits while keeping
;: the retained name/value budget explicit.
(define (default-response-trailer-limits) : HttpResponseTrailerLimits
  (HttpResponseTrailerLimits 65536 8192 100 1024 8192 65536))

;: True when every bound is positive, internally ordered, and sufficient for
;: the mandatory final CRLF.
(define (response-trailer-limits-valid?
  [limits : (& limits HttpResponseTrailerLimits)]) : bool
  (and
    (>= limits.max-total-bytes 2)
    (> limits.max-line-bytes 0)
    (> limits.max-fields 0)
    (> limits.max-name-bytes 0)
    (> limits.max-value-bytes 0)
    (> limits.max-retained-bytes 0)
    (<= limits.max-line-bytes limits.max-total-bytes)
    (<= limits.max-name-bytes limits.max-line-bytes)
    (<= limits.max-value-bytes limits.max-line-bytes)
    (<= limits.max-retained-bytes limits.max-total-bytes)))

;: Reuse the shared byte-oriented field-line grammar with trailer bounds.
(define (response-trailer-head-limits
  [limits : (& limits HttpResponseTrailerLimits)]) : http_types.HttpHeadLimits
  (http_types.HttpHeadLimits
    limits.max-total-bytes
    limits.max-line-bytes
    limits.max-fields
    limits.max-name-bytes
    limits.max-value-bytes))

;: Add nonnegative values below a nonnegative cap, returning `-1` on overflow
;: or cap violation.
(define (response-trailer-bounded-add
  [current : i64]
  [amount : i64]
  [limit : i64]) : i64
  (if (or
    (< current 0)
    (< amount 0)
    (< limit current)
    (> amount (- limit current)))
    -1
    (+ current amount)))

;: Bound direct declaration-set inputs before the generic invariant walk, then
;: require every normalized name to fit the parser's own name policy. Advisory
;: declarations are already retained by the head and do not consume the
;: trailer field-retention budget.
(define (response-trailer-declared-valid?
  [declared : (& declared http_types.HttpHeaderNameSet)]
  [limits : (& limits HttpResponseTrailerLimits)]) : bool
  (if (or (< declared.len 0) (> declared.len limits.max-fields))
    false
    (if (not (http_types.header-name-set-valid? declared))
      false
      (let
        [index : i64 0]
        [valid : bool true]
        (begin
          (while (and valid (< index declared.len))
            (let
              [name : (& declared bytes)
                (http_types.header-name-set-ref declared index)]
              [name-len : i64 (byte_buf.bytes-length name)]
              (begin
                (if (> name-len limits.max-name-bytes)
                  (set! valid false)
                  unit)
                (set! index (+ index 1)))))
          valid)))))

;: Construct a local configuration/API error.
(define (response-trailer-local-error
  [kind : HttpResponseTrailerErrorKind]
  [field-index : i64]
  [offset : i64]) : HttpResponseTrailerError
  (HttpResponseTrailerError kind field-index offset false))

;: Construct a connection-poisoning peer-input error.
(define (response-trailer-peer-error
  [kind : HttpResponseTrailerErrorKind]
  [field-index : i64]
  [offset : i64]) : HttpResponseTrailerError
  (HttpResponseTrailerError kind field-index offset true))

;: Preserve one shared field-grammar error without retaining peer bytes.
(define (response-trailer-field-error
  [error : http_types.HttpHeadError]
  [field-index : i64]) : HttpResponseTrailerError
  (response-trailer-peer-error
    (HttpResponseTrailerFieldError error.kind)
    field-index
    error.offset))

;: Preserve one shared trailer-policy error without retaining peer bytes.
(define (response-trailer-policy-error
  [error : http_trailer_policy.HttpTrailerError]) : HttpResponseTrailerError
  (response-trailer-peer-error
    (HttpResponseTrailerPolicyError error.kind)
    error.index
    error.offset))

;: Construct a parser only after local limits, policy, and declaration-set
;: representation have been validated.
(define (response-trailer-parser-new
  [limits : HttpResponseTrailerLimits]
  [policy : http_trailer_policy.HttpTrailerPolicy]
  [declared : http_types.HttpHeaderNameSet]) : HttpResponseTrailerParserNewResult
  (cond
    [(not (response-trailer-limits-valid? (& limits)))
      (HttpResponseTrailerParserNewErr
        (response-trailer-local-error (HttpResponseTrailerInvalidLimits) 0 0))]
    [(not (http_trailer_policy.trailer-policy-valid? (& policy)))
      (HttpResponseTrailerParserNewErr
        (response-trailer-local-error (HttpResponseTrailerCorruptPolicy) 0 0))]
    [(not (response-trailer-declared-valid? (& declared) (& limits)))
      (HttpResponseTrailerParserNewErr
        (response-trailer-local-error
          (HttpResponseTrailerInvalidDeclaredNames)
          0
          0))]
    [else
      (HttpResponseTrailerParserNewOk
        (HttpResponseTrailerParser
          (byte_buf.with-capacity
            (if (< limits.max-line-bytes 256)
              limits.max-line-bytes
              256))
          0
          false
          0
          0
          (http_types.headers-empty)
          declared
          policy
          limits
          (HttpResponseTrailerOpen)))]))

;: Number of wire bytes accepted from the trailer section so far.
(define (response-trailer-parser-consumed
  [parser : (& parser HttpResponseTrailerParser)]) : i64
  parser.total-bytes)

;: Number of retained name/value bytes so far.
(define (response-trailer-parser-retained-bytes
  [parser : (& parser HttpResponseTrailerParser)]) : i64
  parser.retained-bytes)

;: Parse, classify, and retain one completed nonempty line, or recognize the
;: empty-line terminator. Every resource and policy decision precedes copying
;: the checked name/value ranges.
(define (process-completed-response-trailer-line
  [parser : (&mut parser HttpResponseTrailerParser)]) : HttpResponseTrailerLineResult
  (let
    [line-len : i64 (byte_buf.len (& parser.line))]
    [field-index : i64 parser.fields.len]
    (if (= line-len 0)
      (HttpResponseTrailerLineComplete)
      (if (>= field-index parser.limits.max-fields)
        (HttpResponseTrailerLineErr
          (response-trailer-peer-error
            (HttpResponseTrailerPolicyError
              (http_trailer_policy.HttpTrailerTooManyFields))
            field-index
            parser.line-start))
        (let
          [line : (& parser bytes) (byte_buf.as-bytes (& parser.line))]
          [field-limits : http_types.HttpHeadLimits
            (response-trailer-head-limits (& parser.limits))]
          (match (http_types.validate-field-line-parts
            line
            parser.line-start
            (& field-limits))
            [(http_types.HttpFieldLinePartsErr error)
              (HttpResponseTrailerLineErr
                (response-trailer-field-error error field-index))]
            [(http_types.HttpFieldLinePartsOk parts)
              (let
                [next-retained-0 : i64
                  (response-trailer-bounded-add
                    parser.retained-bytes
                    parts.name-len
                    parser.limits.max-retained-bytes)]
                [next-retained : i64
                  (response-trailer-bounded-add
                    next-retained-0
                    parts.value-len
                    parser.limits.max-retained-bytes)]
                (if (< next-retained 0)
                  (HttpResponseTrailerLineErr
                    (response-trailer-peer-error
                      (HttpResponseTrailerRetainedBytesExceeded)
                      field-index
                      parser.line-start))
                  (let
                    [name : (& parser bytes)
                      (byte_buf.bytes-slice-view line 0 parts.name-len)]
                    (match (http_trailer_policy.trailer-field-disposition
                      (& parser.policy)
                      (& parser.fields)
                      field-index
                      name
                      (& parser.declared)
                      false
                      parser.line-start)
                      [(http_trailer_policy.HttpTrailerFieldDispositionErr
                          error)
                        (HttpResponseTrailerLineErr
                          (response-trailer-policy-error error))]
                      [(http_trailer_policy.HttpTrailerFieldDispositionOk
                          sensitivity)
                        (let
                          [field : http_types.HttpHeaderField
                            (http_types.copy-field-line-parts
                              line
                              parts
                              sensitivity)]
                          (begin
                            (http_types.headers-push!
                              (&mut parser.fields)
                              field)
                            (set! parser.retained-bytes next-retained)
                            (HttpResponseTrailerLineContinue)))]))))]))))))

;: Feed one borrowed byte slice, stopping at the exact final CRLF. Invalid
;: bytes are counted as consumed by the failing call but never enter scratch.
(define (response-trailer-parser-feed
  [parser : HttpResponseTrailerParser]
  [input : (& input bytes)]) : HttpResponseTrailerFeedResult
  (match (clone parser.state)
    [(HttpResponseTrailerComplete) (HttpResponseTrailerFeedComplete parser 0)]
    [(HttpResponseTrailerFailed terminal-error)
      (HttpResponseTrailerFeedErr parser terminal-error 0)]
    [(HttpResponseTrailerOpen)
      (let
        [input-len : i64 (byte_buf.bytes-length input)]
        [consumed : i64 0]
        [done : bool false]
        [result-kind : i64 0]
        [failure : HttpResponseTrailerError
          (response-trailer-peer-error
            (HttpResponseTrailerTruncatedTerminator)
            parser.fields.len
            parser.total-bytes)]
        (begin
          (while (and (< consumed input-len) (not done))
            (let
              [byte : u8 (byte_buf.bytes-ref input consumed)]
              [code : i64 (cast byte : i64)]
              (if parser.saw-cr
                (if (= code 10)
                  (if (>= parser.total-bytes parser.limits.max-total-bytes)
                    (begin
                      (set!
                        failure
                        (response-trailer-peer-error
                          (HttpResponseTrailerSectionTooLarge)
                          parser.fields.len
                          parser.total-bytes))
                      (set! consumed (+ consumed 1))
                      (set! result-kind 2)
                      (set! done true))
                    (begin
                      (set! parser.total-bytes (+ parser.total-bytes 1))
                      (set! parser.saw-cr false)
                      (set! consumed (+ consumed 1))
                      (match (process-completed-response-trailer-line
                        (&mut parser))
                        [(HttpResponseTrailerLineErr error)
                          (begin
                            (set! failure error)
                            (set! result-kind 2)
                            (set! done true))]
                        [(HttpResponseTrailerLineComplete)
                          (begin
                            (set! result-kind 1)
                            (set! done true))]
                        [(HttpResponseTrailerLineContinue)
                          (begin
                            (set! parser.line.len 0)
                            (set! parser.line-start parser.total-bytes))])))
                  (begin
                    (set!
                      failure
                      (response-trailer-peer-error
                        (HttpResponseTrailerFieldError
                          (http_types.HttpBareCarriageReturn))
                        parser.fields.len
                        (- parser.total-bytes 1)))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true)))
                (cond
                  [(= code 10)
                    (begin
                      (set!
                        failure
                        (response-trailer-peer-error
                          (HttpResponseTrailerFieldError
                            (http_types.HttpBareLineFeed))
                          parser.fields.len
                          parser.total-bytes))
                      (set! consumed (+ consumed 1))
                      (set! result-kind 2)
                      (set! done true))]
                  [(= code 0)
                    (begin
                      (set!
                        failure
                        (response-trailer-peer-error
                          (HttpResponseTrailerFieldError
                            (http_types.HttpNulByte))
                          parser.fields.len
                          parser.total-bytes))
                      (set! consumed (+ consumed 1))
                      (set! result-kind 2)
                      (set! done true))]
                  [(or (and (< code 32) (!= code 13) (!= code 9)) (= code 127))
                    (begin
                      (set!
                        failure
                        (response-trailer-peer-error
                          (HttpResponseTrailerFieldError
                            (http_types.HttpInvalidControlByte))
                          parser.fields.len
                          parser.total-bytes))
                      (set! consumed (+ consumed 1))
                      (set! result-kind 2)
                      (set! done true))]
                  [(>= parser.total-bytes parser.limits.max-total-bytes)
                    (begin
                      (set!
                        failure
                        (response-trailer-peer-error
                          (HttpResponseTrailerSectionTooLarge)
                          parser.fields.len
                          parser.total-bytes))
                      (set! consumed (+ consumed 1))
                      (set! result-kind 2)
                      (set! done true))]
                  [(= code 13)
                    (begin
                      (set! parser.saw-cr true)
                      (set! parser.total-bytes (+ parser.total-bytes 1))
                      (set! consumed (+ consumed 1)))]
                  [(>=
                      (byte_buf.len (& parser.line))
                      parser.limits.max-line-bytes)
                    (begin
                      (set!
                        failure
                        (response-trailer-peer-error
                          (HttpResponseTrailerFieldError
                            (http_types.HttpLineTooLong))
                          parser.fields.len
                          parser.total-bytes))
                      (set! consumed (+ consumed 1))
                      (set! result-kind 2)
                      (set! done true))]
                  [else
                    (begin
                      (set! parser.line (byte_buf.push parser.line byte))
                      (set! parser.total-bytes (+ parser.total-bytes 1))
                      (set! consumed (+ consumed 1)))]))))
          (cond
            [(= result-kind 1)
              (begin
                (set! parser.state (HttpResponseTrailerComplete))
                (HttpResponseTrailerFeedComplete parser consumed))]
            [(= result-kind 2)
              (begin
                (set! parser.state (HttpResponseTrailerFailed (clone failure)))
                (HttpResponseTrailerFeedErr parser failure consumed))]
            [else (HttpResponseTrailerFeedNeedInput parser consumed)])))]))

;: Finish at explicit EOF, preserving an existing terminal state or reporting
;: the first missing byte and whether a field or final terminator was pending.
(define (response-trailer-parser-finish [parser : HttpResponseTrailerParser]) : HttpResponseTrailerFinishResult
  (match (clone parser.state)
    [(HttpResponseTrailerComplete) (HttpResponseTrailerFinishComplete parser)]
    [(HttpResponseTrailerFailed terminal-error)
      (HttpResponseTrailerFinishErr parser terminal-error)]
    [(HttpResponseTrailerOpen)
      (let
        [failure : HttpResponseTrailerError
          (if parser.saw-cr
            (response-trailer-peer-error
              (HttpResponseTrailerFieldError
                (http_types.HttpBareCarriageReturn))
              parser.fields.len
              (- parser.total-bytes 1))
            (response-trailer-peer-error
              (if (> (byte_buf.len (& parser.line)) 0)
                (HttpResponseTrailerTruncatedField)
                (HttpResponseTrailerTruncatedTerminator))
              parser.fields.len
              parser.total-bytes))]
        (begin
          (set! parser.state (HttpResponseTrailerFailed (clone failure)))
          (HttpResponseTrailerFinishErr parser failure)))]))

;: Consume a completed parser and return the separate ordered trailers. Open
;: or failed parsers return a stable local/terminal error and no fields.
(define (response-trailer-parser-into-fields
  [parser : HttpResponseTrailerParser]) : HttpResponseTrailerFieldsResult
  (match parser.state
    [(HttpResponseTrailerComplete) (HttpResponseTrailerFieldsOk parser.fields)]
    [(HttpResponseTrailerFailed terminal-error)
      (HttpResponseTrailerFieldsErr terminal-error)]
    [(HttpResponseTrailerOpen)
      (HttpResponseTrailerFieldsErr
        (response-trailer-local-error
          (HttpResponseTrailerIncompleteResult)
          parser.fields.len
          parser.total-bytes))]))