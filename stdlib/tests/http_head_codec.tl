(import stdlib.byte_buf)
(import stdlib.net.http_head_codec)
(import stdlib.net.http_types)
(import stdlib.string)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (field
  [name : String]
  [value : String]
  [sensitivity : http_types.HttpHeaderSensitivity]) : http_types.HttpHeaderField
  (http_types.HttpHeaderField
    (http_types.HttpHeaderName (byte_buf.from-string name))
    (http_types.HttpHeaderValue (byte_buf.from-string value))
    sensitivity))

(define (public-field [name : String] [value : String]) : http_types.HttpHeaderField
  (field name value (http_types.HttpHeaderPublic)))

(define (headers-one [name : String] [value : String]) : http_types.HttpHeaders
  (http_types.headers-append
    (http_types.headers-empty)
    (public-field name value)))

(define (header-value-string
  [headers : (& headers http_types.HttpHeaders)]
  [index : i64]) : String
  (let
    [field : (& headers http_types.HttpHeaderField)
      (http_types.headers-ref headers index)]
    (byte_buf.bytes-to-string (http_types.header-value-bytes (& field.value)))))

(define (assert-request-basic) : unit
  (let
    [headers : http_types.HttpHeaders (headers-one "Host" "example.test")]
    [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
    (match (http_head_codec.serialize-request-head
      (http_types.HttpMethod (byte_buf.from-string "GET"))
      (http_types.HttpRequestTarget (byte_buf.from-string "/path?q=1"))
      headers
      (http_types.HttpRequestBodyNone)
      limits)
      [(http_head_codec.HttpRequestSerializeErr _)
        (fail "basic request rejected")]
      [(http_head_codec.HttpRequestSerializeOk serialized)
        (let
          [actual : String (byte_buf.to-string serialized.bytes)]
          [expected : String
            "GET /path?q=1 HTTP/1.1\r\nHost: example.test\r\n\r\n"]
          (begin
            (test.assert-string-eq
              (& actual)
              (& expected)
              "basic request bytes")
            (match serialized.body-plan
              [(http_types.HttpRequestPlanNone) unit]
              [_ (fail "basic request body plan")])))])))

(define (assert-request-framing) : unit
  (begin
    (let
      [headers : http_types.HttpHeaders (http_types.headers-empty)]
      (begin
        (set!
          headers
          (http_types.headers-append headers (public-field "Host" "x")))
        (set!
          headers
          (http_types.headers-append
            headers
            (public-field "content-length" "5, 5")))
        (set!
          headers
          (http_types.headers-append
            headers
            (public-field "Content-Length" "5")))
        (match (http_head_codec.serialize-request-head
          (http_types.HttpMethod (byte_buf.from-string "POST"))
          (http_types.HttpRequestTarget (byte_buf.from-string "/"))
          headers
          (http_types.HttpRequestBodyFixed 5)
          (http_types.default-head-limits))
          [(http_head_codec.HttpRequestSerializeErr _)
            (fail "identical content lengths rejected")]
          [(http_head_codec.HttpRequestSerializeOk serialized)
            (let
              [actual : String (byte_buf.to-string serialized.bytes)]
              [expected : String
                "POST / HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\n\r\n"]
              (begin
                (test.assert-string-eq
                  (& actual)
                  (& expected)
                  "content length canonicalized")
                (match serialized.body-plan
                  [(http_types.HttpRequestPlanFixed length)
                    (test.assert-i64-eq length 5 "fixed plan length")]
                  [_ (fail "fixed plan variant")])))])))
    (let
      [headers : http_types.HttpHeaders (http_types.headers-empty)]
      (begin
        (set!
          headers
          (http_types.headers-append headers (public-field "Host" "x")))
        (set!
          headers
          (http_types.headers-append
            headers
            (public-field "Trailer" "X-Sum, x-meta")))
        (match (http_head_codec.serialize-request-head
          (http_types.HttpMethod (byte_buf.from-string "POST"))
          (http_types.HttpRequestTarget (byte_buf.from-string "/upload"))
          headers
          (http_types.HttpRequestBodyChunked
            (http_types.Http11ChunkedAuthorized))
          (http_types.default-head-limits))
          [(http_head_codec.HttpRequestSerializeErr _)
            (fail "authorized chunked request rejected")]
          [(http_head_codec.HttpRequestSerializeOk serialized)
            (let
              [actual : String (byte_buf.to-string serialized.bytes)]
              [expected : String
                "POST /upload HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\nTrailer: x-sum, x-meta\r\n\r\n"]
              (begin
                (test.assert-string-eq
                  (& actual)
                  (& expected)
                  "chunked request canonical bytes")
                (match serialized.body-plan
                  [(http_types.HttpRequestPlanChunked _ names)
                    (begin
                      (test.assert-i64-eq
                        (http_types.header-name-set-len (& names))
                        2
                        "chunked trailer count")
                      (let
                        [first : String
                          (byte_buf.bytes-to-string
                            (http_types.header-name-set-ref (& names) 0))]
                        [expected-first : String "x-sum"]
                        (test.assert-string-eq
                          (& first)
                          (& expected-first)
                          "trailer normalized")))]
                  [_ (fail "chunked plan variant")])))])))))

(define (assert-request-rejections) : unit
  (begin
    (let
      [headers : http_types.HttpHeaders (http_types.headers-empty)]
      (begin
        (set!
          headers
          (http_types.headers-append headers (public-field "Host" "x")))
        (set!
          headers
          (http_types.headers-append
            headers
            (public-field "Content-Length" "1")))
        (set!
          headers
          (http_types.headers-append
            headers
            (public-field "Transfer-Encoding" "chunked")))
        (match (http_head_codec.serialize-request-head
          (http_types.HttpMethod (byte_buf.from-string "POST"))
          (http_types.HttpRequestTarget (byte_buf.from-string "/"))
          headers
          (http_types.HttpRequestBodyFixed 1)
          (http_types.default-head-limits))
          [(http_head_codec.HttpRequestSerializeErr error)
            (begin
              (test.assert-false
                error.poison-connection
                "local rejection not poison")
              (match error.kind
                [(http_types.HttpTransferEncodingWithContentLength) unit]
                [_ (fail "TE plus CL error kind")]))]
          [_ (fail "TE plus CL request accepted")])))
    (let
      [headers : http_types.HttpHeaders (headers-one "host" "x")]
      (match (http_head_codec.serialize-request-head
        (http_types.HttpMethod (byte_buf.from-string "GET"))
        (http_types.HttpRequestTarget (byte_buf.from-string "http://bad/"))
        headers
        (http_types.HttpRequestBodyNone)
        (http_types.default-head-limits))
        [(http_head_codec.HttpRequestSerializeErr error)
          (match error.kind
            [(http_types.HttpInvalidRequestTarget) unit]
            [_ (fail "absolute target error kind")])]
        [_ (fail "absolute-form target accepted")]))
    (let
      [headers : http_types.HttpHeaders (headers-one "Authorization" "secret")]
      (match (http_head_codec.serialize-request-head
        (http_types.HttpMethod (byte_buf.from-string "GET"))
        (http_types.HttpRequestTarget (byte_buf.from-string "/"))
        headers
        (http_types.HttpRequestBodyNone)
        (http_types.default-head-limits))
        [(http_head_codec.HttpRequestSerializeErr error)
          (match error.kind
            [(http_types.HttpSensitiveHeaderMustBeMarked) unit]
            [_ (fail "sensitivity error kind")])]
        [_ (fail "public Authorization accepted")]))))

(define (assert-fixed-response
  [head : http_types.HttpResponseHead]
  [expected-consumed : i64]) : unit
  (begin
    (test.assert-i64-eq head.status.code 200 "response status")
    (test.assert-i64-eq head.consumed expected-consumed "head consumed")
    (match head.body-plan
      [(http_types.HttpResponsePlanFixed length)
        (test.assert-i64-eq length 5 "response fixed length")]
      [_ (fail "response fixed plan")])
    (let
      [name : String "content-length"]
      [name-bytes : (& name bytes) (byte_buf.str-as-bytes (& name))]
      [index : i64 (http_types.headers-find (& head.headers) name-bytes)]
      (begin
        (test.assert-true (>= index 0) "canonical content length present")
        (let
          [actual : String (header-value-string (& head.headers) index)]
          [expected : String "5"]
          (test.assert-string-eq
            (& actual)
            (& expected)
            "canonical response length"))))))

(define (assert-response-suffix) : unit
  (let
    [wire : String
      "HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\nCONTENT-LENGTH: 5\r\nX-Test: yes\r\n\r\nBODY-and-a-large-suffix"]
    [head-only : String
      "HTTP/1.1 200 OK\r\nContent-Length: 5, 5\r\nCONTENT-LENGTH: 5\r\nX-Test: yes\r\n\r\n"]
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [parser : http_head_codec.HttpResponseParser
      (http_head_codec.response-parser-default
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied))]
    (match (http_head_codec.response-parser-feed parser view)
      [(http_head_codec.HttpResponseFeedComplete head consumed)
        (begin
          (test.assert-i64-eq
            consumed
            (string.string-length (& head-only))
            "same-buffer suffix unconsumed")
          (assert-fixed-response head (string.string-length (& head-only))))]
      [_ (fail "coalesced response did not complete")])))

(define (assert-one-byte-response-suffix) : unit
  (let
    [wire : String "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\nX"]
    [head-text : String "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n"]
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [parser : http_head_codec.HttpResponseParser
      (http_head_codec.response-parser-default
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied))]
    (match (http_head_codec.response-parser-feed parser view)
      [(http_head_codec.HttpResponseFeedComplete head consumed)
        (begin
          (test.assert-i64-eq
            consumed
            (string.string-length (& head-text))
            "one-byte suffix unconsumed")
          (test.assert-i64-eq
            head.consumed
            (string.string-length (& head-text))
            "one-byte suffix head boundary"))]
      [_ (fail "one-byte coalesced suffix rejected")])))

(define (assert-large-response-suffix) : unit
  (let
    [head-text : String "HTTP/1.1 200 OK\r\nContent-Length: 1\r\n\r\n"]
    [wire : byte_buf.ByteBuf (byte_buf.from-string (clone head-text))]
    [index : i64 0]
    (begin
      (while (< index 32768)
        (begin
          (set! wire (byte_buf.push wire (cast 120 : u8)))
          (set! index (+ index 1))))
      (let
        [view : (& wire bytes) (byte_buf.as-bytes (& wire))]
        [parser : http_head_codec.HttpResponseParser
          (http_head_codec.response-parser-default
            (http_types.HttpResponseToOther)
            (http_types.HttpConnectDenied))]
        (match (http_head_codec.response-parser-feed parser view)
          [(http_head_codec.HttpResponseFeedComplete head consumed)
            (begin
              (test.assert-i64-eq
                consumed
                (string.string-length (& head-text))
                "large suffix unconsumed")
              (test.assert-i64-eq
                head.consumed
                (string.string-length (& head-text))
                "large suffix head boundary"))]
          [_ (fail "large coalesced suffix rejected")])))))

(define (assert-every-split) : unit
  (let
    [wire : String "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n"]
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [n : i64 (byte_buf.bytes-length view)]
    [split : i64 0]
    ;; The wrapper makes the split loop's final unit result explicit.
    ;; lint-allow: single-begin
    (begin
      (while (<= split n)
        (let
          [left : (& wire bytes) (byte_buf.bytes-slice-view view 0 split)]
          [right : (& wire bytes)
            (byte_buf.bytes-slice-view view split (- n split))]
          [parser : http_head_codec.HttpResponseParser
            (http_head_codec.response-parser-default
              (http_types.HttpResponseToOther)
              (http_types.HttpConnectDenied))]
          (begin
            (match (http_head_codec.response-parser-feed parser left)
              [(http_head_codec.HttpResponseFeedNeedInput next first-consumed)
                (begin
                  (test.assert-i64-eq
                    first-consumed
                    split
                    "first split consumed")
                  (match (http_head_codec.response-parser-feed next right)
                    [(http_head_codec.HttpResponseFeedComplete
                        head
                        second-consumed)
                      (begin
                        (test.assert-i64-eq
                          second-consumed
                          (- n split)
                          "second split consumed")
                        (assert-fixed-response head n))]
                    [_ (fail "fragmented response did not complete")]))]
              [(http_head_codec.HttpResponseFeedComplete head consumed)
                (begin
                  (test.assert-i64-eq split n "early split completion")
                  (test.assert-i64-eq consumed n "full split consumed")
                  (assert-fixed-response head n))]
              [_ (fail "fragmented response rejected")])
            (set! split (+ split 1))))
        unit))))

(define (assert-response-plan
  [wire : String]
  [method : http_types.HttpResponseRequestMethod]
  [connect : http_types.HttpConnectCapability]
  [expected : i64]) : unit
  (let
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [parser : http_head_codec.HttpResponseParser
      (http_head_codec.response-parser-default method connect)]
    (match (http_head_codec.response-parser-feed parser view)
      [(http_head_codec.HttpResponseFeedComplete head _)
        (match head.body-plan
          [(http_types.HttpResponsePlanNone)
            (test.assert-i64-eq expected 0 "none response plan")]
          [(http_types.HttpResponsePlanChunked)
            (test.assert-i64-eq expected 1 "chunked response plan")]
          [(http_types.HttpResponsePlanCloseDelimited)
            (test.assert-i64-eq expected 2 "close response plan")]
          [(http_types.HttpResponsePlanTunnel)
            (test.assert-i64-eq expected 3 "tunnel response plan")]
          [(http_types.HttpResponsePlanUnsupportedTransferCoding framing)
            (match framing
              [(http_types.HttpWireChunked)
                (test.assert-i64-eq expected 4 "unsupported chunked plan")]
              [(http_types.HttpWireCloseDelimited)
                (test.assert-i64-eq expected 5 "unsupported close plan")])]
          [(http_types.HttpResponsePlanFixed _) (fail "unexpected fixed plan")])]
      [_ (fail "response plan input rejected")])))

(define (assert-response-semantics) : unit
  (begin
    (assert-response-plan
      "HTTP/1.1 200 OK\r\nContent-Length: 99\r\n\r\n"
      (http_types.HttpResponseToHead)
      (http_types.HttpConnectDenied)
      0)
    (assert-response-plan
      "HTTP/1.1 204 No Content\r\nContent-Length: 7\r\n\r\n"
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied)
      0)
    (assert-response-plan
      "HTTP/1.1 304 Not Modified\r\n\r\n"
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied)
      0)
    (assert-response-plan
      "HTTP/1.1 103 Early Hints\r\n\r\n"
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied)
      0)
    (assert-response-plan
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: gzip, chunked\r\n\r\n"
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied)
      4)
    (assert-response-plan
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied)
      1)
    (assert-response-plan
      "HTTP/1.1 200 OK\r\n\r\n"
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied)
      2)
    (assert-response-plan
      "HTTP/1.1 200 Connection Established\r\n\r\n"
      (http_types.HttpResponseToConnect)
      (http_types.HttpConnectAuthorized)
      3)))

(define (assert-response-error
  [wire : String]
  [expected-offset : i64]
  [expected-kind : i64]) : unit
  (let
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [parser : http_head_codec.HttpResponseParser
      (http_head_codec.response-parser-default
        (http_types.HttpResponseToOther)
        (http_types.HttpConnectDenied))]
    (match (http_head_codec.response-parser-feed parser view)
      [(http_head_codec.HttpResponseFeedErr error _)
        (begin
          (test.assert-true error.poison-connection "peer error poisons")
          (test.assert-i64-eq
            error.offset
            expected-offset
            "stable error offset")
          (match error.kind
            [(http_types.HttpBareLineFeed)
              (test.assert-i64-eq expected-kind 0 "bare LF kind")]
            [(http_types.HttpInvalidFieldName)
              (test.assert-i64-eq expected-kind 1 "field whitespace kind")]
            [(http_types.HttpObsoleteLineFold)
              (test.assert-i64-eq expected-kind 2 "obs-fold kind")]
            [(http_types.HttpContentLengthOverflow)
              (test.assert-i64-eq expected-kind 3 "length overflow kind")]
            [(http_types.HttpTransferEncodingWithContentLength)
              (test.assert-i64-eq expected-kind 4 "TE plus CL kind")]
            [(http_types.HttpChunkedCodingNotFinal)
              (test.assert-i64-eq expected-kind 5 "chunked order kind")]
            [_ (fail "unexpected response error kind")]))]
      [_ (fail "malformed response accepted")])))

(define (assert-response-rejections) : unit
  (begin
    (assert-response-error "HTTP/1.1 200 OK\n" 15 0)
    (assert-response-error "HTTP/1.1 200 OK\r\nBad : x\r\n\r\n" 20 1)
    (assert-response-error "HTTP/1.1 200 OK\r\n folded\r\n\r\n" 17 2)
    (assert-response-error
      "HTTP/1.1 200 OK\r\nContent-Length: 9223372036854775808\r\n\r\n"
      51
      3)
    (let
      [wire : String
        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      [parser : http_head_codec.HttpResponseParser
        (http_head_codec.response-parser-default
          (http_types.HttpResponseToOther)
          (http_types.HttpConnectDenied))]
      (match (http_head_codec.response-parser-feed parser view)
        [(http_head_codec.HttpResponseFeedErr error _)
          (match error.kind
            [(http_types.HttpTransferEncodingWithContentLength) unit]
            [_ (fail "TE plus CL response kind")])]
        [_ (fail "TE plus CL response accepted")]))
    (let
      [wire : String
        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked, gzip\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      [parser : http_head_codec.HttpResponseParser
        (http_head_codec.response-parser-default
          (http_types.HttpResponseToOther)
          (http_types.HttpConnectDenied))]
      (match (http_head_codec.response-parser-feed parser view)
        [(http_head_codec.HttpResponseFeedErr error _)
          (match error.kind
            [(http_types.HttpChunkedCodingNotFinal) unit]
            [_ (fail "chunked order response kind")])]
        [_ (fail "non-final chunked accepted")]))
    (let
      [wire : String "HTTP/1.1 200 Connection Established\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      [parser : http_head_codec.HttpResponseParser
        (http_head_codec.response-parser-default
          (http_types.HttpResponseToConnect)
          (http_types.HttpConnectDenied))]
      (match (http_head_codec.response-parser-feed parser view)
        [(http_head_codec.HttpResponseFeedErr error _)
          (match error.kind
            [(http_types.HttpConnectCapabilityRequired) unit]
            [_ (fail "CONNECT capability error kind")])]
        [_ (fail "unauthorized CONNECT tunnel accepted")]))))

(define (assert-limit-error
  [wire : String]
  [limits : http_types.HttpHeadLimits]
  [expected : i64]) : unit
  (let
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    (match (http_head_codec.response-parser-new
      limits
      (http_types.HttpResponseToOther)
      (http_types.HttpConnectDenied))
      [(http_head_codec.HttpResponseParserNewErr _)
        (fail "valid limit set rejected")]
      [(http_head_codec.HttpResponseParserNewOk parser)
        (match (http_head_codec.response-parser-feed parser view)
          [(http_head_codec.HttpResponseFeedErr error _)
            (match error.kind
              [(http_types.HttpHeadTooLarge)
                (test.assert-i64-eq expected 0 "total cap kind")]
              [(http_types.HttpLineTooLong)
                (test.assert-i64-eq expected 1 "line cap kind")]
              [(http_types.HttpTooManyFields)
                (test.assert-i64-eq expected 2 "field cap kind")]
              [(http_types.HttpNameTooLong)
                (test.assert-i64-eq expected 3 "name cap kind")]
              [(http_types.HttpValueTooLong)
                (test.assert-i64-eq expected 4 "value cap kind")]
              [_ (fail "unexpected limit error kind")])]
          [_
            (cond
              [(= expected 0) (fail "total limit violation accepted")]
              [(= expected 1) (fail "line limit violation accepted")]
              [(= expected 2) (fail "field limit violation accepted")]
              [(= expected 3) (fail "name limit violation accepted")]
              [else (fail "value limit violation accepted")])])])))

(define (assert-parser-limits-and-eof) : unit
  (begin
    (assert-limit-error
      "HTTP/1.1 200 OK\r\n\r\n"
      (http_types.HttpHeadLimits 18 18 10 10 10)
      0)
    (assert-limit-error
      "HTTP/1.1 200 OK\r\n\r\n"
      (http_types.HttpHeadLimits 100 10 10 10 10)
      1)
    (assert-limit-error
      "HTTP/1.1 200 OK\r\nA: 1\r\nB: 2\r\n\r\n"
      (http_types.HttpHeadLimits 100 40 1 10 10)
      2)
    (assert-limit-error
      "HTTP/1.1 200 OK\r\nLong: x\r\n\r\n"
      (http_types.HttpHeadLimits 100 40 10 3 10)
      3)
    (assert-limit-error
      "HTTP/1.1 200 OK\r\nX: 1234\r\n\r\n"
      (http_types.HttpHeadLimits 100 40 10 10 3)
      4)
    (let
      [wire : String "HTTP/1.1 200 OK\r\nX: unfinished"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      [parser : http_head_codec.HttpResponseParser
        (http_head_codec.response-parser-default
          (http_types.HttpResponseToOther)
          (http_types.HttpConnectDenied))]
      (match (http_head_codec.response-parser-feed parser view)
        [(http_head_codec.HttpResponseFeedNeedInput next consumed)
          (begin
            (test.assert-i64-eq
              consumed
              (string.string-length (& wire))
              "truncated prefix consumed")
            (match (http_head_codec.response-parser-finish next)
              [(http_head_codec.HttpResponseFinishErr error)
                (match error.kind
                  [(http_types.HttpTruncatedHead) unit]
                  [_ (fail "truncated finish kind")])]
              [_ (fail "truncated parser marked complete")]))]
        [_ (fail "truncated parser feed outcome")]))))

(define (assert-field-validator) : unit
  (let
    [line : String "X-Custom:\t kept bytes \t"]
    [view : (& line bytes) (byte_buf.str-as-bytes (& line))]
    [limits : http_types.HttpHeadLimits (http_types.default-head-limits)]
    (match (http_types.validate-field-line
      view
      100
      (& limits)
      (http_types.HttpHeaderSensitive))
      [(http_types.HttpFieldLineErr _) (fail "field validator rejected")]
      [(http_types.HttpFieldLineOk checked)
        (let
          [actual : String
            (byte_buf.bytes-to-string
              (http_types.header-value-bytes (& checked.value)))]
          [expected : String "kept bytes"]
          (begin
            (test.assert-string-eq (& actual) (& expected) "field OWS trim")
            (match (http_types.header-debug-disposition (& checked))
              [(http_types.HttpHeaderDebugRedacted) unit]
              [_ (fail "sensitive debug disposition")])))])))

(define (main) : i64
  (begin
    (assert-request-basic)
    (assert-request-framing)
    (assert-request-rejections)
    (assert-response-suffix)
    (assert-one-byte-response-suffix)
    (assert-large-response-suffix)
    (assert-every-split)
    (assert-response-semantics)
    (assert-response-rejections)
    (assert-parser-limits-and-eof)
    (assert-field-validator)
    42))