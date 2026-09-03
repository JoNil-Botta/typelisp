;# Bounded strict HTTP/1.1 request-head serialization and response-head parsing.
;#
;# Response parsing is byte incremental. Each accepted byte is examined once,
;# completed lines are parsed once, and `HttpResponseFeedComplete.consumed`
;# stops exactly after the empty-line CRLF. A caller-owned suffix is never
;# copied into parser storage. All peer syntax/framing errors poison the
;# connection; request construction errors do not.
;#
;# This module performs no I/O and imports no socket, TLS, or host runtime API.
;# Its owned byte buffers allocate in the active arena.
;#
;# Usage: `(import stdlib.net.http_head_codec)`.
(import stdlib.byte_buf)
(import stdlib.net.http_trailer_policy)
(import stdlib.net.http_types)
(import stdlib.string)

;: Recoverable request-head serialization result.
(defenum HttpRequestSerializeResult
  (HttpRequestSerializeOk http_types.HttpSerializedRequestHead)
  (HttpRequestSerializeErr http_types.HttpHeadError))

;: Internal checked-length result used before request output allocation.
(defenum HttpLengthResult
  (HttpLengthOk i64)
  (HttpLengthErr http_types.HttpHeadError))

;: Internal response status-line parse result.
(defenum HttpStatusLineResult
  (HttpStatusLineOk http_types.HttpStatus http_types.HttpReason)
  (HttpStatusLineErr http_types.HttpHeadError))

;: Framing facts accumulated in wire order while fields are parsed.
(defstruct HttpFramingState
  (saw-content-length bool)
  (content-length i64)
  (saw-transfer-encoding bool)
  (transfer-coding-count i64)
  (chunked-seen bool)
  (unsupported-coding-seen bool))

;: Result of applying one Content-Length field to framing state.
(defenum HttpContentLengthResult
  (HttpContentLengthOk HttpFramingState)
  (HttpContentLengthErr http_types.HttpHeadError))

;: Result of applying one Transfer-Encoding field to framing state.
(defenum HttpTransferEncodingResult
  (HttpTransferEncodingOk HttpFramingState)
  (HttpTransferEncodingErr http_types.HttpHeadError))

;: Result of validating one Connection field's option names.
(defenum HttpConnectionFieldResult
  (HttpConnectionFieldOk)
  (HttpConnectionFieldErr http_types.HttpHeadError))

;: Result of applying one parsed response field to framing state.
(defenum HttpResponseFieldResult
  (HttpResponseFieldOk HttpFramingState)
  (HttpResponseFieldErr http_types.HttpHeadError))

;: Result of selecting response body semantics after all framing fields parse.
(defenum HttpResponsePlanResult
  (HttpResponsePlanOk http_types.HttpResponseBodyPlan)
  (HttpResponsePlanErr http_types.HttpHeadError))

;: Result of collecting one Trailer declaration.
(defenum HttpTrailerNamesResult
  (HttpTrailerNamesOk http_types.HttpHeaderNameSet)
  (HttpTrailerNamesErr http_types.HttpHeadError))

;: Incremental response-head parser. `line-start` and `head-bytes` are absolute
;: offsets within `buffer`; completed prefixes are never scanned again.
(defstruct HttpResponseParser
  (buffer byte_buf.ByteBuf)
  (line-start i64)
  (saw-cr bool)
  (status-parsed bool)
  (status-code i64)
  (reason http_types.HttpReason)
  (headers http_types.HttpHeaders)
  (framing HttpFramingState)
  (limits http_types.HttpHeadLimits)
  (request-method http_types.HttpResponseRequestMethod)
  (connect-capability http_types.HttpConnectCapability))

;: One incremental feed outcome. `consumed` is relative to this feed call.
;: NeedInput threads the parser forward; Complete owns the checked head.
(defenum HttpResponseFeedResult
  (HttpResponseFeedNeedInput HttpResponseParser i64)
  (HttpResponseFeedComplete http_types.HttpResponseHead i64)
  (HttpResponseFeedErr http_types.HttpHeadError i64))

;: End-of-input outcome used to turn an incomplete head into a stable error.
(defenum HttpResponseFinishResult
  (HttpResponseFinishErr http_types.HttpHeadError)
  (HttpResponseFinishAlreadyComplete http_types.HttpHeadError))

;: Recoverable parser construction result, including invalid local limits.
(defenum HttpResponseParserNewResult
  (HttpResponseParserNewOk HttpResponseParser)
  (HttpResponseParserNewErr http_types.HttpHeadError))

;: Internal result of parsing one newly completed line exactly once.
(defenum HttpParserLineResult
  (HttpParserLineContinue)
  (HttpParserLineComplete http_types.HttpResponseBodyPlan)
  (HttpParserLineErr http_types.HttpHeadError))

;: Return an empty framing accumulator.
(define (framing-empty) : HttpFramingState
  (HttpFramingState false 0 false 0 false false))

;: Return true when `value` equals an ASCII string literal ignoring case.
(define (bytes-eq-ascii-string [value : (& value bytes)] [spelling : String]) : bool
  (let
    [expected : (& spelling bytes) (byte_buf.str-as-bytes (& spelling))]
    (http_types.bytes-eq-ascii-case value expected)))

;: Return true when `name` equals an ASCII string literal ignoring case.
(define (name-eq-string
  [name : (& name http_types.HttpHeaderName)]
  [spelling : String]) : bool
  (let
    [expected : (& spelling bytes) (byte_buf.str-as-bytes (& spelling))]
    (http_types.header-name-eq name expected)))

;: Return true for SP or HTAB.
(define (ows-byte? [byte : u8]) : bool
  (let
    [code : i64 (cast byte : i64)]
    (or (= code 32) (= code 9))))

;: Skip optional whitespace in `value` starting at `index`.
(define (skip-ows [value : (& value bytes)] [index : i64]) : i64
  (let
    [cursor : i64 index]
    [n : i64 (byte_buf.bytes-length value)]
    (begin
      (while (and (< cursor n) (ows-byte? (byte_buf.bytes-ref value cursor)))
        (set! cursor (+ cursor 1)))
      cursor)))

;: Return the offset of the first byte after a token starting at `index`.
(define (skip-token [value : (& value bytes)] [index : i64]) : i64
  (let
    [cursor : i64 index]
    [n : i64 (byte_buf.bytes-length value)]
    (begin
      (while (and
        (< cursor n)
        (http_types.token-byte? (byte_buf.bytes-ref value cursor)))
        (set! cursor (+ cursor 1)))
      cursor)))

;: Compare byte range `[start, end)` with an ASCII spelling ignoring case.
(define (byte-range-eq-ascii-string
  [value : (& value bytes)]
  [start : i64]
  [end : i64]
  [spelling : String]) : bool
  (let
    [expected : (& spelling bytes) (byte_buf.str-as-bytes (& spelling))]
    [count : i64 (- end start)]
    [index : i64 0]
    [same : bool (= count (byte_buf.bytes-length expected))]
    (begin
      (while (and same (< index count))
        (begin
          (if (!=
            (http_types.ascii-lower (byte_buf.bytes-ref value (+ start index)))
            (http_types.ascii-lower (byte_buf.bytes-ref expected index)))
            (set! same false)
            unit)
          (set! index (+ index 1))))
      same)))

;: Add `amount` while enforcing `limit`, without overflowing signed i64.
(define (checked-length-add
  [current : i64]
  [amount : i64]
  [limit : i64]
  [kind : http_types.HttpHeadErrorKind]
  [offset : i64]) : HttpLengthResult
  (if (or (< amount 0) (> amount (- limit current)))
    (HttpLengthErr (http_types.local-error kind offset))
    (HttpLengthOk (+ current amount))))

;: Parse an exact strict HTTP/1.1 response status line without its CRLF.
(define (parse-status-line [line : (& line bytes)] [base-offset : i64]) : HttpStatusLineResult
  (let
    [n : i64 (byte_buf.bytes-length line)]
    [prefix : String "HTTP/1.1 "]
    [prefix-bytes : (& prefix bytes) (byte_buf.str-as-bytes (& prefix))]
    [index : i64 0]
    [bad-prefix : i64 -1]
    (begin
      (while (and (< index 9) (< index n) (< bad-prefix 0))
        (begin
          (if (!=
            (byte_buf.bytes-ref line index)
            (byte_buf.bytes-ref prefix-bytes index))
            (set! bad-prefix index)
            unit)
          (set! index (+ index 1))))
      (cond
        [(< n 9)
          (HttpStatusLineErr
            (http_types.peer-error
              (http_types.HttpInvalidVersion)
              (+ base-offset n)))]
        [(>= bad-prefix 0)
          (HttpStatusLineErr
            (http_types.peer-error
              (http_types.HttpInvalidVersion)
              (+ base-offset bad-prefix)))]
        [(< n 13)
          (HttpStatusLineErr
            (http_types.peer-error
              (http_types.HttpInvalidStatus)
              (+ base-offset n)))]
        [else
          (let
            [d0 : i64 (cast (byte_buf.bytes-ref line 9) : i64)]
            [d1 : i64 (cast (byte_buf.bytes-ref line 10) : i64)]
            [d2 : i64 (cast (byte_buf.bytes-ref line 11) : i64)]
            (cond
              [(or (< d0 48) (> d0 57) (< d1 48) (> d1 57) (< d2 48) (> d2 57))
                (let
                  [bad : i64
                    (if (or (< d0 48) (> d0 57))
                      9
                      (if (or (< d1 48) (> d1 57))
                        10
                        11))]
                  (HttpStatusLineErr
                    (http_types.peer-error
                      (http_types.HttpInvalidStatus)
                      (+ base-offset bad))))]
              [(!= (cast (byte_buf.bytes-ref line 12) : i64) 32)
                (HttpStatusLineErr
                  (http_types.peer-error
                    (http_types.HttpInvalidStatus)
                    (+ base-offset 12)))]
              [else
                (let
                  [status : i64
                    (+ (* (- d0 48) 100) (* (- d1 48) 10) (- d2 48))]
                  [scan : i64 13]
                  [bad-reason : i64 -1]
                  (begin
                    (while (and (< scan n) (< bad-reason 0))
                      (let
                        [code : i64 (cast (byte_buf.bytes-ref line scan) : i64)]
                        (begin
                          (if (or
                            (= code 0)
                            (= code 10)
                            (= code 13)
                            (and (< code 32) (!= code 9))
                            (= code 127))
                            (set! bad-reason scan)
                            unit)
                          (set! scan (+ scan 1)))))
                    (cond
                      [(or (< status 100) (> status 599))
                        (HttpStatusLineErr
                          (http_types.peer-error
                            (http_types.HttpInvalidStatus)
                            (+ base-offset 9)))]
                      [(>= bad-reason 0)
                        (HttpStatusLineErr
                          (http_types.peer-error
                            (if (=
                              (cast (byte_buf.bytes-ref line bad-reason) : i64)
                              0)
                              (http_types.HttpNulByte)
                              (http_types.HttpInvalidReason))
                            (+ base-offset bad-reason)))]
                      [else
                        (HttpStatusLineOk
                          (http_types.HttpStatus status)
                          (http_types.HttpReason
                            (http_types.copy-byte-range line 13 (- n 13))))])))]))]))))

;: Parse one comma-list Content-Length field with checked decimal arithmetic.
(define (apply-content-length
  [state : HttpFramingState]
  [value : (& value bytes)]
  [base-offset : i64]) : HttpContentLengthResult
  (let
    [n : i64 (byte_buf.bytes-length value)]
    [cursor : i64 0]
    [failed : bool false]
    [error-kind : http_types.HttpHeadErrorKind
      (http_types.HttpMalformedContentLength)]
    [error-offset : i64 base-offset]
    [parsed-any : bool false]
    [canonical-set : bool state.saw-content-length]
    [canonical : i64 state.content-length]
    (begin
      (while (and (< cursor n) (not failed))
        (begin
          (set! cursor (skip-ows value cursor))
          (let
            [digit-start : i64 cursor]
            [number : i64 0]
            (begin
              (while (and
                (< cursor n)
                (let
                  [code : i64 (cast (byte_buf.bytes-ref value cursor) : i64)]
                  (and (>= code 48) (<= code 57)))
                (not failed))
                (let
                  [digit : i64
                    (- (cast (byte_buf.bytes-ref value cursor) : i64) 48)]
                  (begin
                    (if (> number (/ (- 9223372036854775807 digit) 10))
                      (begin
                        (set! failed true)
                        (set! error-kind (http_types.HttpContentLengthOverflow))
                        (set! error-offset (+ base-offset cursor)))
                      (set! number (+ (* number 10) digit)))
                    (set! cursor (+ cursor 1)))))
              (if (and (not failed) (= digit-start cursor))
                (begin
                  (set! failed true)
                  (set! error-offset (+ base-offset cursor)))
                unit)
              (if (not failed)
                (begin
                  (set! parsed-any true)
                  (if canonical-set
                    (if (!= canonical number)
                      (begin
                        (set! failed true)
                        (set!
                          error-kind
                          (http_types.HttpConflictingContentLength))
                        (set! error-offset (+ base-offset digit-start)))
                      unit)
                    (begin
                      (set! canonical number)
                      (set! canonical-set true))))
                unit)
              (if (not failed)
                (begin
                  (set! cursor (skip-ows value cursor))
                  (if (< cursor n)
                    (if (= (cast (byte_buf.bytes-ref value cursor) : i64) 44)
                      (begin
                        (set! cursor (+ cursor 1))
                        (if (= (skip-ows value cursor) n)
                          (begin
                            (set! failed true)
                            (set! error-offset (+ base-offset cursor)))
                          unit))
                      (begin
                        (set! failed true)
                        (set! error-offset (+ base-offset cursor))))
                    unit))
                unit)))))
      (if (or failed (not parsed-any))
        (HttpContentLengthErr (http_types.peer-error error-kind error-offset))
        (HttpContentLengthOk
          (HttpFramingState
            true
            canonical
            state.saw-transfer-encoding
            state.transfer-coding-count
            state.chunked-seen
            state.unsupported-coding-seen))))))

;: Skip one quoted transfer-parameter value, returning `-1` on malformed input.
(define (skip-transfer-quoted-value [value : (& value bytes)] [index : i64]) : i64
  (let
    [n : i64 (byte_buf.bytes-length value)]
    [cursor : i64 (+ index 1)]
    [closed : bool false]
    [failed : bool false]
    (begin
      (while (and (< cursor n) (not closed) (not failed))
        (let
          [code : i64 (cast (byte_buf.bytes-ref value cursor) : i64)]
          (cond
            [(= code 34)
              (begin
                (set! closed true)
                (set! cursor (+ cursor 1)))]
            [(= code 92)
              (if (>= (+ cursor 1) n)
                (set! failed true)
                (let
                  [escaped : i64
                    (cast (byte_buf.bytes-ref value (+ cursor 1)) : i64)]
                  (if (or
                    (= escaped 9)
                    (and (>= escaped 32) (<= escaped 126))
                    (>= escaped 128))
                    (set! cursor (+ cursor 2))
                    (set! failed true))))]
            [(or
                (= code 9)
                (= code 32)
                (= code 33)
                (and (>= code 35) (<= code 91))
                (and (>= code 93) (<= code 126))
                (>= code 128))
              (set! cursor (+ cursor 1))]
            [else (set! failed true)])))
      (if (and closed (not failed))
        cursor
        -1))))

;: Parse transfer codings in exact order and update the authoritative framing
;: state. Unknown codings remain valid syntax but mark decoding unsupported.
(define (apply-transfer-encoding
  [state : HttpFramingState]
  [value : (& value bytes)]
  [base-offset : i64]) : HttpTransferEncodingResult
  (let
    [n : i64 (byte_buf.bytes-length value)]
    [cursor : i64 0]
    [failed : bool false]
    [error-kind : http_types.HttpHeadErrorKind
      (http_types.HttpMalformedTransferEncoding)]
    [error-offset : i64 base-offset]
    [count : i64 state.transfer-coding-count]
    [chunked : bool state.chunked-seen]
    [unsupported : bool state.unsupported-coding-seen]
    [parsed-any : bool false]
    (begin
      (while (and (< cursor n) (not failed))
        (begin
          (set! cursor (skip-ows value cursor))
          (let
            [coding-start : i64 cursor]
            [coding-end : i64 (skip-token value cursor)]
            [is-chunked : bool false]
            [has-parameters : bool false]
            ;; The single wrapper keeps the complete transfer-coding step one
            ;; unit-valued loop body while its branches update shared state.
            ;; lint-allow: single-begin
            (begin
              (if (= coding-start coding-end)
                (begin
                  (set! failed true)
                  (set! error-offset (+ base-offset cursor)))
                (begin
                  (set!
                    is-chunked
                    (byte-range-eq-ascii-string
                      value
                      coding-start
                      coding-end
                      "chunked"))
                  (set! cursor coding-end)
                  (set! cursor (skip-ows value cursor))
                  (while (and
                    (not failed)
                    (< cursor n)
                    (= (cast (byte_buf.bytes-ref value cursor) : i64) 59))
                    (begin
                      (set! has-parameters true)
                      (set! cursor (skip-ows value (+ cursor 1)))
                      (let
                        [parameter-name-start : i64 cursor]
                        [parameter-name-end : i64 (skip-token value cursor)]
                        (if (= parameter-name-start parameter-name-end)
                          (begin
                            (set! failed true)
                            (set! error-offset (+ base-offset cursor)))
                          (begin
                            (set! cursor (skip-ows value parameter-name-end))
                            (if (or
                              (>= cursor n)
                              (!=
                                (cast (byte_buf.bytes-ref value cursor) : i64)
                                61))
                              (begin
                                (set! failed true)
                                (set! error-offset (+ base-offset cursor)))
                              (begin
                                (set! cursor (skip-ows value (+ cursor 1)))
                                (if (>= cursor n)
                                  (begin
                                    (set! failed true)
                                    (set! error-offset (+ base-offset cursor)))
                                  (if (=
                                    (cast
                                      (byte_buf.bytes-ref value cursor)
                                      : i64)
                                    34)
                                    (let
                                      [next : i64
                                        (skip-transfer-quoted-value
                                          value
                                          cursor)]
                                      (if (< next 0)
                                        (begin
                                          (set! failed true)
                                          (set!
                                            error-offset
                                            (+ base-offset cursor)))
                                        (set! cursor next)))
                                    (let
                                      [parameter-value-end : i64
                                        (skip-token value cursor)]
                                      (if (= parameter-value-end cursor)
                                        (begin
                                          (set! failed true)
                                          (set!
                                            error-offset
                                            (+ base-offset cursor)))
                                        (set! cursor parameter-value-end))))))))))
                      (set! cursor (skip-ows value cursor))))
                  (if (and (not failed) is-chunked has-parameters)
                    (begin
                      (set! failed true)
                      (set! error-offset (+ base-offset coding-start)))
                    unit)
                  (if (not failed)
                    (cond
                      [(and is-chunked chunked)
                        (begin
                          (set! failed true)
                          (set!
                            error-kind
                            (http_types.HttpDuplicateChunkedCoding))
                          (set! error-offset (+ base-offset coding-start)))]
                      [chunked
                        (begin
                          (set! failed true)
                          (set!
                            error-kind
                            (http_types.HttpChunkedCodingNotFinal))
                          (set! error-offset (+ base-offset coding-start)))]
                      [else
                        (begin
                          (set! parsed-any true)
                          (set! count (+ count 1))
                          (if is-chunked
                            (set! chunked true)
                            (set! unsupported true)))])
                    unit)
                  (if (not failed)
                    (begin
                      (set! cursor (skip-ows value cursor))
                      (if (< cursor n)
                        (if (=
                          (cast (byte_buf.bytes-ref value cursor) : i64)
                          44)
                          (begin
                            (set! cursor (+ cursor 1))
                            (if (= (skip-ows value cursor) n)
                              (begin
                                (set! failed true)
                                (set! error-offset (+ base-offset cursor)))
                              unit))
                          (begin
                            (set! failed true)
                            (set! error-offset (+ base-offset cursor))))
                        unit))
                    unit)))))))
      (if (or failed (not parsed-any))
        (HttpTransferEncodingErr
          (http_types.peer-error error-kind error-offset))
        (HttpTransferEncodingOk
          (HttpFramingState
            state.saw-content-length
            state.content-length
            true
            count
            chunked
            unsupported))))))

;: True when a Connection option would obscure routing or message framing.
(define (connection-option-forbidden?
  [value : (& value bytes)]
  [start : i64]
  [end : i64]) : bool
  (or
    (byte-range-eq-ascii-string value start end "connection")
    (byte-range-eq-ascii-string value start end "content-length")
    (byte-range-eq-ascii-string value start end "transfer-encoding")
    (byte-range-eq-ascii-string value start end "trailer")
    (byte-range-eq-ascii-string value start end "host")
    (byte-range-eq-ascii-string value start end "proxy-authorization")))

;: Validate a Connection option list and reject framing-critical nominations.
(define (validate-connection-field
  [value : (& value bytes)]
  [base-offset : i64]) : HttpConnectionFieldResult
  (let
    [n : i64 (byte_buf.bytes-length value)]
    [cursor : i64 0]
    [failed : bool false]
    [error-offset : i64 base-offset]
    [parsed-any : bool false]
    (begin
      (while (and (< cursor n) (not failed))
        (begin
          (set! cursor (skip-ows value cursor))
          (let
            [start : i64 cursor]
            [end : i64 (skip-token value cursor)]
            (if (= start end)
              (begin
                (set! failed true)
                (set! error-offset (+ base-offset cursor)))
              (begin
                (set! parsed-any true)
                (if (connection-option-forbidden? value start end)
                  (begin
                    (set! failed true)
                    (set! error-offset (+ base-offset start)))
                  (begin
                    (set! cursor (skip-ows value end))
                    (if (< cursor n)
                      (if (= (cast (byte_buf.bytes-ref value cursor) : i64) 44)
                        (begin
                          (set! cursor (+ cursor 1))
                          (if (= (skip-ows value cursor) n)
                            (begin
                              (set! failed true)
                              (set! error-offset (+ base-offset cursor)))
                            unit))
                        (begin
                          (set! failed true)
                          (set! error-offset (+ base-offset cursor))))
                      unit))))))))
      (if (or failed (not parsed-any))
        (HttpConnectionFieldErr
          (http_types.peer-error
            (http_types.HttpForbiddenConnectionHeader)
            error-offset))
        (HttpConnectionFieldOk)))))

;: Return the value's wire offset from a parsed field line and line base.
(define (field-value-offset [line : (& line bytes)] [base-offset : i64]) : i64
  (let
    [n : i64 (byte_buf.bytes-length line)]
    [cursor : i64 0]
    [colon : i64 0]
    [found : bool false]
    (begin
      (while (and (< cursor n) (not found))
        (if (= (cast (byte_buf.bytes-ref line cursor) : i64) 58)
          (begin
            (set! colon cursor)
            (set! found true))
          (set! cursor (+ cursor 1))))
      (set! cursor (+ colon 1))
      (while (and (< cursor n) (ows-byte? (byte_buf.bytes-ref line cursor)))
        (set! cursor (+ cursor 1)))
      (+ base-offset cursor))))

;: Apply a checked response field to framing state and enforce fail-closed
;: Transfer-Encoding plus Content-Length handling.
(define (apply-response-field
  [state : HttpFramingState]
  [field : (& field http_types.HttpHeaderField)]
  [value-offset : i64]) : HttpResponseFieldResult
  (let
    [value : (& field bytes) (http_types.header-value-bytes (& field.value))]
    (cond
      [(name-eq-string (& field.name) "content-length")
        (match (apply-content-length state value value-offset)
          [(HttpContentLengthErr error) (HttpResponseFieldErr error)]
          [(HttpContentLengthOk next)
            (if next.saw-transfer-encoding
              (HttpResponseFieldErr
                (http_types.peer-error
                  (http_types.HttpTransferEncodingWithContentLength)
                  value-offset))
              (HttpResponseFieldOk next))])]
      [(name-eq-string (& field.name) "transfer-encoding")
        (match (apply-transfer-encoding state value value-offset)
          [(HttpTransferEncodingErr error) (HttpResponseFieldErr error)]
          [(HttpTransferEncodingOk next)
            (if next.saw-content-length
              (HttpResponseFieldErr
                (http_types.peer-error
                  (http_types.HttpTransferEncodingWithContentLength)
                  value-offset))
              (HttpResponseFieldOk next))])]
      [(name-eq-string (& field.name) "connection")
        (match (validate-connection-field value value-offset)
          [(HttpConnectionFieldOk) (HttpResponseFieldOk state)]
          [(HttpConnectionFieldErr error) (HttpResponseFieldErr error)])]
      [(name-eq-string (& field.name) "proxy-connection")
        (HttpResponseFieldErr
          (http_types.peer-error
            (http_types.HttpForbiddenConnectionHeader)
            value-offset))]
      [else (HttpResponseFieldOk state)])))

;: Parse and normalize one Trailer declaration field.
(define (apply-trailer-names
  [set : http_types.HttpHeaderNameSet]
  [value : (& value bytes)]
  [base-offset : i64]
  [max-name-bytes : i64]) : HttpTrailerNamesResult
  (let
    [n : i64 (byte_buf.bytes-length value)]
    [cursor : i64 0]
    [failed : bool false]
    [forbidden : bool false]
    [name-too-long : bool false]
    [error-offset : i64 base-offset]
    [parsed-any : bool false]
    (begin
      (while (and (< cursor n) (not failed))
        (begin
          (set! cursor (skip-ows value cursor))
          (let
            [start : i64 cursor]
            [end : i64 (skip-token value cursor)]
            [name : (& value bytes)
              (byte_buf.bytes-slice-view value start (- end start))]
            (if (= start end)
              (begin
                (set! failed true)
                (set! error-offset (+ base-offset cursor)))
              (begin
                (set! parsed-any true)
                (if (> (- end start) max-name-bytes)
                  (begin
                    (set! failed true)
                    (set! name-too-long true)
                    (set! error-offset (+ base-offset max-name-bytes)))
                  unit)
                (if (and
                  (not failed)
                  (http_trailer_policy.trailer-name-forbidden-bytes? name))
                  (begin
                    (set! failed true)
                    (set! forbidden true)
                    (set! error-offset (+ base-offset start)))
                  (if (not failed)
                    (set! set (http_types.header-name-set-add set name))
                    unit))
                (if (not failed)
                  (begin
                    (set! cursor (skip-ows value end))
                    (if (< cursor n)
                      (if (= (cast (byte_buf.bytes-ref value cursor) : i64) 44)
                        (begin
                          (set! cursor (+ cursor 1))
                          (if (= (skip-ows value cursor) n)
                            (begin
                              (set! failed true)
                              (set! error-offset (+ base-offset cursor)))
                            unit))
                        (begin
                          (set! failed true)
                          (set! error-offset (+ base-offset cursor))))
                      unit))
                  unit))))))
      (if (or failed (not parsed-any))
        (HttpTrailerNamesErr
          (http_types.peer-error
            (if name-too-long
              (http_types.HttpNameTooLong)
              (if forbidden
                (http_types.HttpForbiddenTrailerName)
                (http_types.HttpMalformedTrailerDeclaration)))
            error-offset))
        (HttpTrailerNamesOk set)))))

;: Select body semantics after a complete response head.
(define (select-response-plan
  [state : (& state HttpFramingState)]
  [status : i64]
  [method : http_types.HttpResponseRequestMethod]
  [connect-capability : http_types.HttpConnectCapability]
  [offset : i64]) : HttpResponsePlanResult
  (match method
    [(http_types.HttpResponseToHead)
      (HttpResponsePlanOk (http_types.HttpResponsePlanNone))]
    [(http_types.HttpResponseToConnect)
      ;; CONNECT first gates tunnel promotion, then applies ordinary response
      ;; framing to unsuccessful statuses.
      ;; lint-allow: nested-if-ladder
      (if (and (>= status 200) (< status 300))
        (match connect-capability
          [(http_types.HttpConnectAuthorized)
            (HttpResponsePlanOk (http_types.HttpResponsePlanTunnel))]
          [(http_types.HttpConnectDenied)
            (HttpResponsePlanErr
              (http_types.peer-error
                (http_types.HttpConnectCapabilityRequired)
                offset))])
        (if (or
          (and (>= status 100) (< status 200))
          (= status 204)
          (= status 304))
          (HttpResponsePlanOk (http_types.HttpResponsePlanNone))
          (if state.saw-transfer-encoding
            (if state.chunked-seen
              (if state.unsupported-coding-seen
                (HttpResponsePlanOk
                  (http_types.HttpResponsePlanUnsupportedTransferCoding
                    (http_types.HttpWireChunked)))
                (HttpResponsePlanOk (http_types.HttpResponsePlanChunked)))
              (HttpResponsePlanOk
                (http_types.HttpResponsePlanUnsupportedTransferCoding
                  (http_types.HttpWireCloseDelimited))))
            (if state.saw-content-length
              (HttpResponsePlanOk
                (http_types.HttpResponsePlanFixed state.content-length))
              (HttpResponsePlanOk (http_types.HttpResponsePlanCloseDelimited))))))]
    [(http_types.HttpResponseToOther)
      ;; Body semantics intentionally follow RFC precedence in this order.
      ;; lint-allow: nested-if-ladder
      (if (or
        (and (>= status 100) (< status 200))
        (= status 204)
        (= status 304))
        (HttpResponsePlanOk (http_types.HttpResponsePlanNone))
        (if state.saw-transfer-encoding
          (if state.chunked-seen
            (if state.unsupported-coding-seen
              (HttpResponsePlanOk
                (http_types.HttpResponsePlanUnsupportedTransferCoding
                  (http_types.HttpWireChunked)))
              (HttpResponsePlanOk (http_types.HttpResponsePlanChunked)))
            (HttpResponsePlanOk
              (http_types.HttpResponsePlanUnsupportedTransferCoding
                (http_types.HttpWireCloseDelimited))))
          (if state.saw-content-length
            (HttpResponsePlanOk
              (http_types.HttpResponsePlanFixed state.content-length))
            (HttpResponsePlanOk (http_types.HttpResponsePlanCloseDelimited)))))]))

;: Canonicalize all valid Content-Length occurrences to one decimal field at
;: the first occurrence while retaining every other field's relative order.
(define (canonicalize-content-length
  [headers : http_types.HttpHeaders]
  [state : (& state HttpFramingState)]) : http_types.HttpHeaders
  (if (not state.saw-content-length)
    headers
    (let
      [out : http_types.HttpHeaders (http_types.headers-empty)]
      [index : i64 0]
      [emitted : bool false]
      (begin
        (while (< index headers.len)
          (let
            [is-length : bool
              (name-eq-string
                (& (array-ref headers.slots index).name)
                "content-length")]
            (begin
              (if is-length
                (if emitted
                  unit
                  (begin
                    (set! emitted true)
                    (set!
                      out
                      (http_types.headers-append
                        out
                        (http_types.HttpHeaderField
                          (http_types.HttpHeaderName
                            (byte_buf.from-string "Content-Length"))
                          (http_types.HttpHeaderValue
                            (byte_buf.from-string
                              (string.int->string state.content-length)))
                          (http_types.HttpHeaderPublic))))))
                (set!
                  out
                  (http_types.headers-append
                    out
                    (clone (array-ref headers.slots index)))))
              (set! index (+ index 1)))))
        out))))

;: Construct a bounded incremental response parser.
(define (response-parser-new
  [limits : http_types.HttpHeadLimits]
  [request-method : http_types.HttpResponseRequestMethod]
  [connect-capability : http_types.HttpConnectCapability]) : HttpResponseParserNewResult
  (if (not (http_types.head-limits-valid? (& limits)))
    (HttpResponseParserNewErr
      (http_types.local-error (http_types.HttpInvalidLimits) 0))
    (HttpResponseParserNewOk
      (HttpResponseParser
        (byte_buf.with-capacity
          (if (< limits.max-total-bytes 256)
            limits.max-total-bytes
            256))
        0
        false
        false
        0
        (http_types.HttpReason (byte_buf.new))
        (http_types.headers-empty)
        (framing-empty)
        limits
        request-method
        connect-capability))))

;: Construct a parser with `default-head-limits`.
(define (response-parser-default
  [request-method : http_types.HttpResponseRequestMethod]
  [connect-capability : http_types.HttpConnectCapability]) : HttpResponseParser
  (match (response-parser-new
    (http_types.default-head-limits)
    request-method
    connect-capability)
    [(HttpResponseParserNewOk parser) parser]
    [(HttpResponseParserNewErr _)
      (HttpResponseParser
        (byte_buf.new)
        0
        false
        false
        0
        (http_types.HttpReason (byte_buf.new))
        (http_types.headers-empty)
        (framing-empty)
        (http_types.default-head-limits)
        request-method
        connect-capability)]))

;: Parse one line that has just acquired its CRLF. This never revisits an
;: earlier completed line.
(define (process-completed-response-line
  [parser : (&mut parser HttpResponseParser)]) : HttpParserLineResult
  (let
    [head-len : i64 (byte_buf.len parser.buffer)]
    [line-end : i64 (- head-len 2)]
    [line-len : i64 (- line-end parser.line-start)]
    [all-bytes : (& parser bytes) (byte_buf.as-bytes (& parser.buffer))]
    [line : (& parser bytes)
      (byte_buf.bytes-slice-view all-bytes parser.line-start line-len)]
    ;; Status, terminator, and field lines are three distinct parser phases.
    ;; lint-allow: nested-if-ladder
    (if (not parser.status-parsed)
      (match (parse-status-line line parser.line-start)
        [(HttpStatusLineErr error) (HttpParserLineErr error)]
        [(HttpStatusLineOk status reason)
          (begin
            (set! parser.status-parsed true)
            (set! parser.status-code status.code)
            (set! parser.reason reason)
            (set! parser.line-start head-len)
            (HttpParserLineContinue))])
      (if (= line-len 0)
        (let
          [framing : HttpFramingState parser.framing]
          (match (select-response-plan
            (& framing)
            parser.status-code
            (clone parser.request-method)
            (clone parser.connect-capability)
            head-len)
            [(HttpResponsePlanErr error) (HttpParserLineErr error)]
            [(HttpResponsePlanOk plan) (HttpParserLineComplete plan)]))
        (if (>= parser.headers.len parser.limits.max-fields)
          (HttpParserLineErr
            (http_types.peer-error
              (http_types.HttpTooManyFields)
              parser.line-start))
          (let
            [value-offset : i64 (field-value-offset line parser.line-start)]
            (match (http_types.validate-field-line
              line
              parser.line-start
              (& parser.limits)
              (http_types.HttpHeaderPublic))
              [(http_types.HttpFieldLineErr error) (HttpParserLineErr error)]
              [(http_types.HttpFieldLineOk field)
                (begin
                  (if (http_types.header-name-known-sensitive? (& field.name))
                    (set! field.sensitivity (http_types.HttpHeaderSensitive))
                    unit)
                  (match (apply-response-field
                    (clone parser.framing)
                    (& field)
                    value-offset)
                    [(HttpResponseFieldErr error) (HttpParserLineErr error)]
                    [(HttpResponseFieldOk next-framing)
                      (begin
                        (set! parser.framing next-framing)
                        (http_types.headers-push! (&mut parser.headers) field)
                        (set! parser.line-start head-len)
                        (HttpParserLineContinue))]))])))))))

;: Feed one borrowed byte slice. The parser stops at the exact final CRLF and
;: reports only bytes consumed from this call, leaving any suffix untouched.
(define (response-parser-feed
  [parser : HttpResponseParser]
  [input : (& input bytes)]) : HttpResponseFeedResult
  (if (not (http_types.head-limits-valid? (& parser.limits)))
    (HttpResponseFeedErr
      (http_types.local-error (http_types.HttpInvalidLimits) 0)
      0)
    (let
      [input-len : i64 (byte_buf.bytes-length input)]
      [consumed : i64 0]
      [done : bool false]
      [result-kind : i64 0]
      [completed-head : http_types.HttpResponseHead
        (http_types.HttpResponseHead
          (http_types.Http11)
          (http_types.HttpStatus 100)
          (http_types.HttpReason (byte_buf.new))
          (http_types.headers-empty)
          (http_types.HttpResponsePlanNone)
          0)]
      [failure : http_types.HttpHeadError
        (http_types.peer-error (http_types.HttpParserFinished) 0)]
      (begin
        (while (and (< consumed input-len) (not done))
          (let
            [byte : u8 (byte_buf.bytes-ref input consumed)]
            [code : i64 (cast byte : i64)]
            [absolute : i64 (byte_buf.len parser.buffer)]
            (if parser.saw-cr
              (if (= code 10)
                (if (>= absolute parser.limits.max-total-bytes)
                  (begin
                    (set!
                      failure
                      (http_types.peer-error
                        (http_types.HttpHeadTooLarge)
                        absolute))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true))
                  (begin
                    (set! parser.buffer (byte_buf.push parser.buffer byte))
                    (set! parser.saw-cr false)
                    (set! consumed (+ consumed 1))
                    (match (process-completed-response-line (&mut parser))
                      [(HttpParserLineErr error)
                        (begin
                          (set! failure error)
                          (set! result-kind 2)
                          (set! done true))]
                      [(HttpParserLineComplete plan)
                        (let
                          [framing : HttpFramingState parser.framing]
                          [headers : http_types.HttpHeaders
                            (canonicalize-content-length
                              (clone parser.headers)
                              (& framing))]
                          (begin
                            (set!
                              completed-head
                              (http_types.HttpResponseHead
                                (http_types.Http11)
                                (http_types.HttpStatus parser.status-code)
                                (clone parser.reason)
                                headers
                                plan
                                (byte_buf.len parser.buffer)))
                            (set! result-kind 1)
                            (set! done true)))]
                      [(HttpParserLineContinue) unit])))
                (begin
                  (set!
                    failure
                    (http_types.peer-error
                      (http_types.HttpBareCarriageReturn)
                      (- absolute 1)))
                  (set! consumed (+ consumed 1))
                  (set! result-kind 2)
                  (set! done true)))
              (cond
                [(= code 10)
                  (begin
                    (set!
                      failure
                      (http_types.peer-error
                        (http_types.HttpBareLineFeed)
                        absolute))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true))]
                [(= code 0)
                  (begin
                    (set!
                      failure
                      (http_types.peer-error (http_types.HttpNulByte) absolute))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true))]
                [(or (and (< code 32) (!= code 13) (!= code 9)) (= code 127))
                  (begin
                    (set!
                      failure
                      (http_types.peer-error
                        (http_types.HttpInvalidControlByte)
                        absolute))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true))]
                [(>= absolute parser.limits.max-total-bytes)
                  (begin
                    (set!
                      failure
                      (http_types.peer-error
                        (http_types.HttpHeadTooLarge)
                        absolute))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true))]
                [(= code 13)
                  (begin
                    (set! parser.buffer (byte_buf.push parser.buffer byte))
                    (set! parser.saw-cr true)
                    (set! consumed (+ consumed 1)))]
                [(>=
                    (- absolute parser.line-start)
                    parser.limits.max-line-bytes)
                  (begin
                    (set!
                      failure
                      (http_types.peer-error
                        (http_types.HttpLineTooLong)
                        absolute))
                    (set! consumed (+ consumed 1))
                    (set! result-kind 2)
                    (set! done true))]
                [else
                  (begin
                    (set! parser.buffer (byte_buf.push parser.buffer byte))
                    (set! consumed (+ consumed 1)))]))))
        (cond
          [(= result-kind 1) (HttpResponseFeedComplete completed-head consumed)]
          [(= result-kind 2) (HttpResponseFeedErr failure consumed)]
          [else (HttpResponseFeedNeedInput parser consumed)])))))

;: Finish an incomplete parser at end of input, producing a deterministic
;: poisoning error at the first missing or dangling position.
(define (response-parser-finish [parser : HttpResponseParser]) : HttpResponseFinishResult
  (let
    [offset : i64 (byte_buf.len parser.buffer)]
    (if parser.saw-cr
      (HttpResponseFinishErr
        (http_types.peer-error (http_types.HttpBareCarriageReturn) (- offset 1)))
      (HttpResponseFinishErr
        (http_types.peer-error (http_types.HttpTruncatedHead) offset)))))

;: Generic local request-validation result.
(defenum HttpRequestValidationResult
  (HttpRequestValidationOk)
  (HttpRequestValidationErr http_types.HttpHeadError))

;: Accumulated request-header facts used to derive one body plan.
(defstruct HttpRequestHeaderFacts
  (framing HttpFramingState)
  (host-count i64)
  (host-empty bool)
  (saw-trailer bool)
  (trailer-names http_types.HttpHeaderNameSet))

;: Result of checking every caller-supplied request header.
(defenum HttpRequestHeaderFactsResult
  (HttpRequestHeaderFactsOk HttpRequestHeaderFacts)
  (HttpRequestHeaderFactsErr http_types.HttpHeadError))

;: Prepared request framing plus canonical framing-field emission decisions.
(defstruct HttpPreparedRequest
  (body-plan http_types.HttpRequestBodyPlan)
  (emit-content-length bool)
  (content-length i64)
  (emit-transfer-encoding bool)
  (trailer-names http_types.HttpHeaderNameSet))

;: Result of reconciling caller body intent with checked header facts.
(defenum HttpPreparedRequestResult
  (HttpPreparedRequestOk HttpPreparedRequest)
  (HttpPreparedRequestErr http_types.HttpHeadError))

;: Return a local copy of an error kind and offset produced by shared syntax
;: helpers while validating bytes supplied for request construction.
(define (request-localize-error [error : http_types.HttpHeadError]) : http_types.HttpHeadError
  (http_types.local-error error.kind error.offset))

;: Add nonnegative lengths under a nonnegative cap; return `-1` on overflow or
;: cap violation.
(define (bounded-length-add [current : i64] [amount : i64] [limit : i64]) : i64
  (if (or
    (< current 0)
    (< amount 0)
    (< limit current)
    (> amount (- limit current)))
    -1
    (+ current amount)))

;: Validate method and origin-form request-target bytes before output exists.
(define (validate-request-line
  [method : (& method http_types.HttpMethod)]
  [target : (& target http_types.HttpRequestTarget)]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpRequestValidationResult
  (let
    [method-bytes : (& method bytes) (http_types.method-bytes method)]
    [target-bytes : (& target bytes) (http_types.request-target-bytes target)]
    [method-len : i64 (byte_buf.bytes-length method-bytes)]
    [target-len : i64 (byte_buf.bytes-length target-bytes)]
    [index : i64 0]
    [bad-method : i64 -1]
    [bad-target : i64 -1]
    (begin
      (while (and (< index method-len) (< bad-method 0))
        (begin
          (if (not
            (http_types.token-byte? (byte_buf.bytes-ref method-bytes index)))
            (set! bad-method index)
            unit)
          (set! index (+ index 1))))
      (set! index 0)
      (while (and (< index target-len) (< bad-target 0))
        (let
          [code : i64 (cast (byte_buf.bytes-ref target-bytes index) : i64)]
          (begin
            (if (or (< code 33) (> code 126) (= code 35))
              (set! bad-target index)
              unit)
            (set! index (+ index 1)))))
      (let
        [line-size-0 : i64
          (bounded-length-add method-len 1 limits.max-line-bytes)]
        [line-size-1 : i64
          (bounded-length-add line-size-0 target-len limits.max-line-bytes)]
        [line-size-2 : i64
          (bounded-length-add line-size-1 9 limits.max-line-bytes)]
        (cond
          [(= method-len 0)
            (HttpRequestValidationErr
              (http_types.local-error (http_types.HttpInvalidMethod) 0))]
          [(>= bad-method 0)
            (HttpRequestValidationErr
              (http_types.local-error (http_types.HttpInvalidMethod) bad-method))]
          [(or
              (= target-len 0)
              (!= (cast (byte_buf.bytes-ref target-bytes 0) : i64) 47))
            (HttpRequestValidationErr
              (http_types.local-error
                (http_types.HttpInvalidRequestTarget)
                (+ method-len 1)))]
          [(>= bad-target 0)
            (HttpRequestValidationErr
              (http_types.local-error
                (http_types.HttpInvalidRequestTarget)
                (+ (+ method-len 1) bad-target)))]
          [(< line-size-2 0)
            (HttpRequestValidationErr
              (http_types.local-error
                (http_types.HttpLineTooLong)
                limits.max-line-bytes))]
          [else (HttpRequestValidationOk)])))))

;: Validate one already-typed request field's token/value shape and canonical
;: surrounding whitespace without allocating output.
(define (validate-request-field-shape
  [field : (& field http_types.HttpHeaderField)]
  [line-offset : i64]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpRequestValidationResult
  (match (http_types.validate-typed-field field line-offset limits)
    [(http_types.HttpTypedFieldOk) (HttpRequestValidationOk)]
    [(http_types.HttpTypedFieldErr error) (HttpRequestValidationErr error)]))

;: Validate request fields, Host, framing, connection options, and normalized
;: Trailer declarations in caller order.
(define (validate-request-headers
  [headers : (& headers http_types.HttpHeaders)]
  [first-field-offset : i64]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpRequestHeaderFactsResult
  (if (> headers.len limits.max-fields)
    (HttpRequestHeaderFactsErr
      (http_types.local-error (http_types.HttpTooManyFields) first-field-offset))
    (let
      [index : i64 0]
      [line-offset : i64 first-field-offset]
      [failed : bool false]
      [failure : http_types.HttpHeadError
        (http_types.local-error
          (http_types.HttpInvalidFieldName)
          first-field-offset)]
      [framing : HttpFramingState (framing-empty)]
      [host-count : i64 0]
      [host-empty : bool false]
      [saw-trailer : bool false]
      [trailer-names : http_types.HttpHeaderNameSet
        (http_types.header-name-set-empty)]
      (begin
        (while (and (< index headers.len) (not failed))
          (let
            [field : (& headers http_types.HttpHeaderField)
              (& (array-ref headers.slots index))]
            [name : (& headers bytes)
              (http_types.header-name-bytes (& field.name))]
            [value : (& headers bytes)
              (http_types.header-value-bytes (& field.value))]
            [name-len : i64 (byte_buf.bytes-length name)]
            [value-len : i64 (byte_buf.bytes-length value)]
            [value-offset : i64 (+ (+ line-offset name-len) 2)]
            (begin
              (match (validate-request-field-shape field line-offset limits)
                [(HttpRequestValidationErr error)
                  (begin
                    (set! failure error)
                    (set! failed true))]
                [(HttpRequestValidationOk)
                  (cond
                    [(name-eq-string (& field.name) "host")
                      (begin
                        (set! host-count (+ host-count 1))
                        (if (= value-len 0)
                          (set! host-empty true)
                          unit))]
                    [(name-eq-string (& field.name) "proxy-authorization")
                      (begin
                        (set!
                          failure
                          (http_types.local-error
                            (http_types.HttpForbiddenProxyAuthorization)
                            line-offset))
                        (set! failed true))]
                    [(name-eq-string (& field.name) "proxy-connection")
                      (begin
                        (set!
                          failure
                          (http_types.local-error
                            (http_types.HttpForbiddenConnectionHeader)
                            line-offset))
                        (set! failed true))]
                    [(name-eq-string (& field.name) "connection")
                      (match (validate-connection-field value value-offset)
                        [(HttpConnectionFieldErr error)
                          (begin
                            (set! failure (request-localize-error error))
                            (set! failed true))]
                        [(HttpConnectionFieldOk) unit])]
                    [(name-eq-string (& field.name) "content-length")
                      (match (apply-content-length
                        (clone framing)
                        value
                        value-offset)
                        [(HttpContentLengthErr error)
                          (begin
                            (set! failure (request-localize-error error))
                            (set! failed true))]
                        [(HttpContentLengthOk next) (set! framing next)])]
                    [(name-eq-string (& field.name) "transfer-encoding")
                      (match (apply-transfer-encoding
                        (clone framing)
                        value
                        value-offset)
                        [(HttpTransferEncodingErr error)
                          (begin
                            (set! failure (request-localize-error error))
                            (set! failed true))]
                        [(HttpTransferEncodingOk next) (set! framing next)])]
                    [(name-eq-string (& field.name) "trailer")
                      (begin
                        (set! saw-trailer true)
                        (match (apply-trailer-names
                          (clone trailer-names)
                          value
                          value-offset
                          limits.max-name-bytes)
                          [(HttpTrailerNamesErr error)
                            (begin
                              (set! failure (request-localize-error error))
                              (set! failed true))]
                          [(HttpTrailerNamesOk next) (set! trailer-names next)]))]
                    [else unit])])
              (if (not failed)
                (let
                  [next-0 : i64
                    (bounded-length-add
                      line-offset
                      name-len
                      9223372036854775807)]
                  [next-1 : i64
                    (bounded-length-add next-0 value-len 9223372036854775807)]
                  [next-2 : i64
                    (bounded-length-add next-1 4 9223372036854775807)]
                  (if (< next-2 0)
                    (begin
                      (set!
                        failure
                        (http_types.local-error
                          (http_types.HttpHeadTooLarge)
                          line-offset))
                      (set! failed true))
                    (set! line-offset next-2)))
                unit)
              (set! index (+ index 1)))))
        (cond
          [failed (HttpRequestHeaderFactsErr failure)]
          [(and framing.saw-content-length framing.saw-transfer-encoding)
            (HttpRequestHeaderFactsErr
              (http_types.local-error
                (http_types.HttpTransferEncodingWithContentLength)
                first-field-offset))]
          [(= host-count 0)
            (HttpRequestHeaderFactsErr
              (http_types.local-error
                (http_types.HttpMissingHost)
                first-field-offset))]
          [(> host-count 1)
            (HttpRequestHeaderFactsErr
              (http_types.local-error
                (http_types.HttpDuplicateHost)
                first-field-offset))]
          [host-empty
            (HttpRequestHeaderFactsErr
              (http_types.local-error
                (http_types.HttpEmptyHost)
                first-field-offset))]
          [else
            (HttpRequestHeaderFactsOk
              (HttpRequestHeaderFacts
                framing
                host-count
                host-empty
                saw-trailer
                trailer-names))])))))

;: Reconcile request body intent with supplied framing fields and produce the
;: single plan consumed by later body encoding.
(define (prepare-request
  [facts : HttpRequestHeaderFacts]
  [intent : http_types.HttpRequestBodyIntent]
  [offset : i64]) : HttpPreparedRequestResult
  (match intent
    [(http_types.HttpRequestBodyNone)
      (cond
        [facts.framing.saw-transfer-encoding
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpRequestBodyPlanMismatch)
              offset))]
        [(and
            facts.framing.saw-content-length
            (!= facts.framing.content-length 0))
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpRequestBodyPlanMismatch)
              offset))]
        [facts.saw-trailer
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpTrailerWithoutChunked)
              offset))]
        [else
          (HttpPreparedRequestOk
            (HttpPreparedRequest
              (http_types.HttpRequestPlanNone)
              facts.framing.saw-content-length
              0
              false
              facts.trailer-names))])]
    [(http_types.HttpRequestBodyFixed length)
      (cond
        [(< length 0)
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpRequestBodyPlanMismatch)
              offset))]
        [facts.framing.saw-transfer-encoding
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpTransferEncodingWithContentLength)
              offset))]
        [(and
            facts.framing.saw-content-length
            (!= facts.framing.content-length length))
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpRequestBodyPlanMismatch)
              offset))]
        [facts.saw-trailer
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpTrailerWithoutChunked)
              offset))]
        [else
          (HttpPreparedRequestOk
            (HttpPreparedRequest
              (http_types.HttpRequestPlanFixed length)
              true
              length
              false
              facts.trailer-names))])]
    [(http_types.HttpRequestBodyChunked authorization)
      (cond
        [facts.framing.saw-content-length
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpTransferEncodingWithContentLength)
              offset))]
        [(and
            facts.framing.saw-transfer-encoding
            (or
              (!= facts.framing.transfer-coding-count 1)
              (not facts.framing.chunked-seen)
              facts.framing.unsupported-coding-seen))
          (HttpPreparedRequestErr
            (http_types.local-error
              (http_types.HttpRequestTransferCodingUnsupported)
              offset))]
        [else
          (HttpPreparedRequestOk
            (HttpPreparedRequest
              (http_types.HttpRequestPlanChunked
                authorization
                (clone facts.trailer-names))
              false
              0
              true
              facts.trailer-names))])]))

;: True when request serialization replaces all caller occurrences with one
;: canonical framing/declaration field.
(define (request-field-replaced? [name : (& name http_types.HttpHeaderName)]) : bool
  (or
    (name-eq-string name "content-length")
    (name-eq-string name "transfer-encoding")
    (name-eq-string name "trailer")))

;: Compute the complete request-head size and validate generated field lines
;: before allocating or writing the output buffer.
(define (request-output-length
  [method : (& method http_types.HttpMethod)]
  [target : (& target http_types.HttpRequestTarget)]
  [headers : (& headers http_types.HttpHeaders)]
  [prepared : (& prepared HttpPreparedRequest)]
  [limits : (& limits http_types.HttpHeadLimits)]) : HttpLengthResult
  (let
    [method-bytes : (& method bytes) (http_types.method-bytes method)]
    [target-bytes : (& target bytes) (http_types.request-target-bytes target)]
    [total : i64 0]
    [failed : bool false]
    [failure-kind : http_types.HttpHeadErrorKind (http_types.HttpHeadTooLarge)]
    [index : i64 0]
    (begin
      (set!
        total
        (bounded-length-add
          (byte_buf.bytes-length method-bytes)
          1
          limits.max-total-bytes))
      (set!
        total
        (bounded-length-add
          total
          (byte_buf.bytes-length target-bytes)
          limits.max-total-bytes))
      (set! total (bounded-length-add total 11 limits.max-total-bytes))
      (if (< total 0)
        (set! failed true)
        unit)
      (while (and (< index headers.len) (not failed))
        (let
          [field : (& headers http_types.HttpHeaderField)
            (& (array-ref headers.slots index))]
          (begin
            (if (not (request-field-replaced? (& field.name)))
              (let
                [name : (& headers bytes)
                  (http_types.header-name-bytes (& field.name))]
                [value : (& headers bytes)
                  (http_types.header-value-bytes (& field.value))]
                [next-0 : i64
                  (bounded-length-add
                    total
                    (byte_buf.bytes-length name)
                    limits.max-total-bytes)]
                [next-1 : i64
                  (bounded-length-add
                    next-0
                    (byte_buf.bytes-length value)
                    limits.max-total-bytes)]
                [next-2 : i64
                  (bounded-length-add next-1 4 limits.max-total-bytes)]
                (if (< next-2 0)
                  (set! failed true)
                  (set! total next-2)))
              unit)
            (set! index (+ index 1)))))
      (if (and (not failed) prepared.emit-content-length)
        (let
          [digits : String (string.int->string prepared.content-length)]
          [value-len : i64 (string.string-length (& digits))]
          [line-len : i64
            (bounded-length-add 16 value-len limits.max-line-bytes)]
          [field-total : i64
            (bounded-length-add value-len 18 limits.max-total-bytes)]
          [next : i64
            (bounded-length-add total field-total limits.max-total-bytes)]
          (cond
            [(< line-len 0)
              (begin
                (set! failed true)
                (set! failure-kind (http_types.HttpLineTooLong)))]
            [(or
                (> 14 limits.max-name-bytes)
                (> value-len limits.max-value-bytes))
              (begin
                (set! failed true)
                (set!
                  failure-kind
                  (if (> 14 limits.max-name-bytes)
                    (http_types.HttpNameTooLong)
                    (http_types.HttpValueTooLong))))]
            [(< next 0) (set! failed true)]
            [else (set! total next)]))
        unit)
      (if (and (not failed) prepared.emit-transfer-encoding)
        (let
          [next : i64 (bounded-length-add total 28 limits.max-total-bytes)]
          (cond
            [(or
                (< limits.max-line-bytes 26)
                (< limits.max-name-bytes 17)
                (< limits.max-value-bytes 7))
              (begin
                (set! failed true)
                (set! failure-kind (http_types.HttpLineTooLong)))]
            [(< next 0) (set! failed true)]
            [else (set! total next)]))
        unit)
      (if (and
        (not failed)
        (> (http_types.header-name-set-len (& prepared.trailer-names)) 0))
        (let
          [names-len : i64 0]
          [name-index : i64 0]
          (begin
            (while (and
              (<
                name-index
                (http_types.header-name-set-len (& prepared.trailer-names)))
              (>= names-len 0))
              (let
                [name : (& prepared bytes)
                  (http_types.header-name-set-ref
                    (& prepared.trailer-names)
                    name-index)]
                (begin
                  (if (> name-index 0)
                    (set!
                      names-len
                      (bounded-length-add names-len 2 limits.max-line-bytes))
                    unit)
                  (set!
                    names-len
                    (bounded-length-add
                      names-len
                      (byte_buf.bytes-length name)
                      limits.max-line-bytes))
                  (set! name-index (+ name-index 1)))))
            (let
              [line-len : i64
                (bounded-length-add 9 names-len limits.max-line-bytes)]
              [field-total : i64
                (bounded-length-add names-len 11 limits.max-total-bytes)]
              [next : i64
                (bounded-length-add total field-total limits.max-total-bytes)]
              (cond
                [(or
                    (< names-len 0)
                    (< line-len 0)
                    (< limits.max-name-bytes 7)
                    (> names-len limits.max-value-bytes))
                  (begin
                    (set! failed true)
                    (set! failure-kind (http_types.HttpLineTooLong)))]
                [(< next 0) (set! failed true)]
                [else (set! total next)]))))
        unit)
      (if (not failed)
        (set! total (bounded-length-add total 2 limits.max-total-bytes))
        unit)
      (if (< total 0)
        (set! failed true)
        unit)
      (if failed
        (HttpLengthErr
          (http_types.local-error failure-kind limits.max-total-bytes))
        (HttpLengthOk total)))))

;: Append one canonical `name: value\r\n` request field.
(define (append-request-field
  [out : byte_buf.ByteBuf]
  [field : (& field http_types.HttpHeaderField)]) : byte_buf.ByteBuf
  (let
    [name : (& field bytes) (http_types.header-name-bytes (& field.name))]
    [value : (& field bytes) (http_types.header-value-bytes (& field.value))]
    (byte_buf.append-string
      (byte_buf.append-bytes
        (byte_buf.append-string (byte_buf.append-bytes out name) ": ")
        value)
      "\r\n")))

;: Emit a validated request head. This function is called only after all
;: lengths, fields, and framing decisions have succeeded.
(define (emit-request-head
  [capacity : i64]
  [method : (& method http_types.HttpMethod)]
  [target : (& target http_types.HttpRequestTarget)]
  [headers : (& headers http_types.HttpHeaders)]
  [prepared : (& prepared HttpPreparedRequest)]) : byte_buf.ByteBuf
  (let
    [method-bytes : (& method bytes) (http_types.method-bytes method)]
    [target-bytes : (& target bytes) (http_types.request-target-bytes target)]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity capacity)]
    [index : i64 0]
    (begin
      (set! out (byte_buf.append-bytes out method-bytes))
      (set! out (byte_buf.append-string out " "))
      (set! out (byte_buf.append-bytes out target-bytes))
      (set! out (byte_buf.append-string out " HTTP/1.1\r\n"))
      (while (< index headers.len)
        (let
          [field : (& headers http_types.HttpHeaderField)
            (& (array-ref headers.slots index))]
          (begin
            (if (not (request-field-replaced? (& field.name)))
              (set! out (append-request-field out field))
              unit)
            (set! index (+ index 1)))))
      (if prepared.emit-content-length
        (begin
          (set! out (byte_buf.append-string out "Content-Length: "))
          (set!
            out
            (byte_buf.append-string
              out
              (string.int->string prepared.content-length)))
          (set! out (byte_buf.append-string out "\r\n")))
        unit)
      (if prepared.emit-transfer-encoding
        (set! out (byte_buf.append-string out "Transfer-Encoding: chunked\r\n"))
        unit)
      (if (> (http_types.header-name-set-len (& prepared.trailer-names)) 0)
        (begin
          (set! out (byte_buf.append-string out "Trailer: "))
          (set! index 0)
          (while (<
            index
            (http_types.header-name-set-len (& prepared.trailer-names)))
            (let
              [name : (& prepared bytes)
                (http_types.header-name-set-ref
                  (& prepared.trailer-names)
                  index)]
              (begin
                (if (> index 0)
                  (set! out (byte_buf.append-string out ", "))
                  unit)
                (set! out (byte_buf.append-bytes out name))
                (set! index (+ index 1)))))
          (set! out (byte_buf.append-string out "\r\n")))
        unit)
      (byte_buf.append-string out "\r\n"))))

;: Serialize one strict origin-form HTTP/1.1 request head and return the body
;: plan derived from the exact same validated framing facts. No output buffer
;: is allocated until every validation and size check succeeds.
(define (serialize-request-head
  [method : http_types.HttpMethod]
  [target : http_types.HttpRequestTarget]
  [headers : http_types.HttpHeaders]
  [intent : http_types.HttpRequestBodyIntent]
  [limits : http_types.HttpHeadLimits]) : HttpRequestSerializeResult
  (if (not (http_types.head-limits-valid? (& limits)))
    (HttpRequestSerializeErr
      (http_types.local-error (http_types.HttpInvalidLimits) 0))
    (match (validate-request-line (& method) (& target) (& limits))
      [(HttpRequestValidationErr error) (HttpRequestSerializeErr error)]
      [(HttpRequestValidationOk)
        (let
          [method-bytes : (& method bytes) (http_types.method-bytes (& method))]
          [target-bytes : (& target bytes)
            (http_types.request-target-bytes (& target))]
          [first-field-offset-0 : i64
            (bounded-length-add
              (byte_buf.bytes-length method-bytes)
              (byte_buf.bytes-length target-bytes)
              limits.max-total-bytes)]
          [first-field-offset : i64
            (bounded-length-add first-field-offset-0 12 limits.max-total-bytes)]
          (if (< first-field-offset 0)
            (HttpRequestSerializeErr
              (http_types.local-error
                (http_types.HttpHeadTooLarge)
                limits.max-total-bytes))
            (match (validate-request-headers
              (& headers)
              first-field-offset
              (& limits))
              [(HttpRequestHeaderFactsErr error)
                (HttpRequestSerializeErr error)]
              [(HttpRequestHeaderFactsOk facts)
                (match (prepare-request facts intent first-field-offset)
                  [(HttpPreparedRequestErr error)
                    (HttpRequestSerializeErr error)]
                  [(HttpPreparedRequestOk prepared)
                    (match (request-output-length
                      (& method)
                      (& target)
                      (& headers)
                      (& prepared)
                      (& limits))
                      [(HttpLengthErr error) (HttpRequestSerializeErr error)]
                      [(HttpLengthOk total)
                        (let
                          [out : byte_buf.ByteBuf
                            (emit-request-head
                              total
                              (& method)
                              (& target)
                              (& headers)
                              (& prepared))]
                          (HttpRequestSerializeOk
                            (http_types.HttpSerializedRequestHead
                              out
                              prepared.body-plan)))])])])))])))