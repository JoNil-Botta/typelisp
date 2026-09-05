(import stdlib.byte_buf)
(import stdlib.net.http_trailer as trailer)
(import stdlib.net.http_trailer_policy as trailer_policy)
(import stdlib.net.http_types)
(import stdlib.string)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (name [spelling : String]) : http_types.HttpHeaderName
  (http_types.HttpHeaderName (byte_buf.from-string spelling)))

(define (policy-add-ok
  [policy : trailer_policy.HttpTrailerPolicy]
  [spelling : String]
  [sensitivity : http_types.HttpHeaderSensitivity]
  [multiplicity : trailer_policy.HttpTrailerMultiplicity]) : trailer_policy.HttpTrailerPolicy
  (match (trailer_policy.trailer-policy-add
    policy
    (name spelling)
    sensitivity
    multiplicity)
    [(trailer_policy.HttpTrailerPolicyAddErr _)
      (begin
        (fail "trailer test policy construction")
        (trailer_policy.trailer-policy-empty))]
    [(trailer_policy.HttpTrailerPolicyAddOk next) next]))

(define (sample-policy) : trailer_policy.HttpTrailerPolicy
  (let
    [policy : trailer_policy.HttpTrailerPolicy
      (policy-add-ok
        (trailer_policy.trailer-policy-empty)
        "X-One"
        (http_types.HttpHeaderPublic)
        (trailer_policy.HttpTrailerAtMostOnce))]
    (begin
      (set!
        policy
        (policy-add-ok
          policy
          "X-List"
          (http_types.HttpHeaderPublic)
          (trailer_policy.HttpTrailerRepeatableList)))
      (set!
        policy
        (policy-add-ok
          policy
          "X-Secret"
          (http_types.HttpHeaderSensitive)
          (trailer_policy.HttpTrailerRepeatableSeparate)))
      policy)))

(define (declared-add
  [declared : http_types.HttpHeaderNameSet]
  [spelling : String]) : http_types.HttpHeaderNameSet
  (let
    [spelling-bytes : (& spelling bytes) (byte_buf.str-as-bytes (& spelling))]
    (http_types.header-name-set-add declared spelling-bytes)))

(define (fallback-parser) : trailer.HttpResponseTrailerParser
  (trailer.HttpResponseTrailerParser
    (byte_buf.new)
    0
    false
    0
    0
    (http_types.headers-empty)
    (http_types.header-name-set-empty)
    (trailer_policy.trailer-policy-empty)
    (trailer.default-response-trailer-limits)
    (trailer.HttpResponseTrailerOpen)))

(define (new-parser-with
  [limits : trailer.HttpResponseTrailerLimits]
  [declared : http_types.HttpHeaderNameSet]) : trailer.HttpResponseTrailerParser
  (match (trailer.response-trailer-parser-new limits (sample-policy) declared)
    [(trailer.HttpResponseTrailerParserNewErr _)
      (begin
        (fail "valid trailer parser construction")
        (fallback-parser))]
    [(trailer.HttpResponseTrailerParserNewOk parser) parser]))

(define (new-parser) : trailer.HttpResponseTrailerParser
  (new-parser-with
    (trailer.default-response-trailer-limits)
    (http_types.header-name-set-empty)))

(define (assert-field
  [fields : (& fields http_types.HttpHeaders)]
  [index : i64]
  [expected-name : String]
  [expected-value : String]
  [sensitive : bool]) : unit
  (let
    [field : (& fields http_types.HttpHeaderField)
      (http_types.headers-ref fields index)]
    [actual-name : String
      (byte_buf.bytes-to-string (http_types.header-name-bytes (& field.name)))]
    [actual-value : String
      (byte_buf.bytes-to-string (http_types.header-value-bytes (& field.value)))]
    (begin
      (test.assert-string-eq
        (& actual-name)
        (& expected-name)
        "trailer field name")
      (test.assert-string-eq
        (& actual-value)
        (& expected-value)
        "trailer field value")
      (if sensitive
        (match (http_types.header-debug-disposition field)
          [(http_types.HttpHeaderDebugRedacted) unit]
          [_ (fail "sensitive trailer was visible")])
        (match (http_types.header-debug-disposition field)
          [(http_types.HttpHeaderDebugVisible) unit]
          [_ (fail "public trailer was redacted")])))))

(define (assert-valid-and-suffix) : unit
  (let
    [prefix : String
      "X-One: first\r\nx-list:\t a \t b \t\r\nX-LIST:b\r\nX-Secret: hidden\r\nx-secret: second\r\n\r\n"]
    [wire : String
      "X-One: first\r\nx-list:\t a \t b \t\r\nX-LIST:b\r\nX-Secret: hidden\r\nx-secret: second\r\n\r\nNEXT"]
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [expected-consumed : i64 (string.string-length (& prefix))]
    (match (trailer.response-trailer-parser-feed (new-parser) view)
      [(trailer.HttpResponseTrailerFeedComplete terminal consumed)
        (begin
          (test.assert-i64-eq
            consumed
            expected-consumed
            "trailer exact consumed")
          (test.assert-i64-eq
            (trailer.response-trailer-parser-consumed (& terminal))
            expected-consumed
            "trailer terminal total")
          (test.assert-i64-eq
            (trailer.response-trailer-parser-retained-bytes (& terminal))
            56
            "trailer retained bytes")
          (match (trailer.response-trailer-parser-feed terminal view)
            [(trailer.HttpResponseTrailerFeedComplete stable consumed-again)
              (begin
                (test.assert-i64-eq
                  consumed-again
                  0
                  "complete parser is stable")
                (match (trailer.response-trailer-parser-into-fields stable)
                  [(trailer.HttpResponseTrailerFieldsErr _)
                    (fail "complete parser lost trailers")]
                  [(trailer.HttpResponseTrailerFieldsOk fields)
                    (begin
                      (test.assert-i64-eq fields.len 5 "retained trailer count")
                      (assert-field (& fields) 0 "X-One" "first" false)
                      (assert-field (& fields) 1 "x-list" "a \t b" false)
                      (assert-field (& fields) 2 "X-LIST" "b" false)
                      (assert-field (& fields) 3 "X-Secret" "hidden" true)
                      (assert-field (& fields) 4 "x-secret" "second" true))]))]
            [_ (fail "complete trailer parser consumed suffix")]))]
      [_ (fail "valid response trailers rejected")])))

(define (assert-empty-trailers) : unit
  (let
    [wire : String "\r\nsuffix"]
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [wire-len : i64 (string.string-length (& wire))]
    [split : i64 0]
    (while (<= split 2)
      (let
        [left : (& wire bytes) (byte_buf.bytes-slice-view view 0 split)]
        [right : (& wire bytes)
          (byte_buf.bytes-slice-view view split (- wire-len split))]
        (begin
          (match (trailer.response-trailer-parser-feed (new-parser) left)
            [(trailer.HttpResponseTrailerFeedNeedInput next first-consumed)
              (begin
                (test.assert-i64-eq
                  first-consumed
                  split
                  "empty trailer split prefix")
                (match (trailer.response-trailer-parser-feed next right)
                  [(trailer.HttpResponseTrailerFeedComplete
                      terminal
                      second-consumed)
                    (begin
                      (test.assert-i64-eq
                        second-consumed
                        (- 2 split)
                        "empty trailer split suffix")
                      (match (trailer.response-trailer-parser-into-fields
                        terminal)
                        [(trailer.HttpResponseTrailerFieldsOk fields)
                          (test.assert-i64-eq
                            fields.len
                            0
                            "empty trailer fields")]
                        [_ (fail "empty trailer extraction")]))]
                  [_ (fail "empty response trailer did not complete")]))]
            [(trailer.HttpResponseTrailerFeedComplete terminal consumed)
              (begin
                (test.assert-i64-eq split 2 "empty trailer early completion")
                (test.assert-i64-eq consumed 2 "empty trailer terminator")
                (match (trailer.response-trailer-parser-into-fields terminal)
                  [(trailer.HttpResponseTrailerFieldsOk fields)
                    (test.assert-i64-eq fields.len 0 "empty trailer fields")]
                  [_ (fail "empty trailer extraction")]))]
            [_ (fail "empty response trailers rejected")])
          (set! split (+ split 1))))
      unit)))

(define (assert-valid-every-split) : unit
  (let
    [prefix : String "X-List: a\r\nX-LIST:b\r\n\r\n"]
    [wire : String "X-List: a\r\nX-LIST:b\r\n\r\nSUFFIX"]
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [prefix-len : i64 (string.string-length (& prefix))]
    [wire-len : i64 (string.string-length (& wire))]
    [split : i64 0]
    (while (<= split prefix-len)
      (let
        [left : (& wire bytes) (byte_buf.bytes-slice-view view 0 split)]
        [right : (& wire bytes)
          (byte_buf.bytes-slice-view view split (- wire-len split))]
        (begin
          (match (trailer.response-trailer-parser-feed (new-parser) left)
            [(trailer.HttpResponseTrailerFeedNeedInput next first-consumed)
              (begin
                (test.assert-i64-eq
                  first-consumed
                  split
                  "trailer split first consumed")
                (match (trailer.response-trailer-parser-feed next right)
                  [(trailer.HttpResponseTrailerFeedComplete
                      terminal
                      second-consumed)
                    (begin
                      (test.assert-i64-eq
                        second-consumed
                        (- prefix-len split)
                        "trailer split second consumed")
                      (match (trailer.response-trailer-parser-into-fields
                        terminal)
                        [(trailer.HttpResponseTrailerFieldsOk fields)
                          (test.assert-i64-eq
                            fields.len
                            2
                            "trailer split fields")]
                        [_ (fail "split trailer extraction")]))]
                  [_ (fail "split trailer did not complete")]))]
            [(trailer.HttpResponseTrailerFeedComplete terminal consumed)
              (begin
                (test.assert-i64-eq split prefix-len "early split completion")
                (test.assert-i64-eq consumed prefix-len "full split consumed")
                (match (trailer.response-trailer-parser-into-fields terminal)
                  [(trailer.HttpResponseTrailerFieldsOk fields)
                    (test.assert-i64-eq fields.len 2 "full split fields")]
                  [_ (fail "full split extraction")]))]
            [_ (fail "split trailer rejected")])
          (set! split (+ split 1))))
      unit)))

(define (trailer-error-code
  [error : (& error trailer.HttpResponseTrailerError)]) : i64
  (match (clone error.kind)
    [(trailer.HttpResponseTrailerFieldError field-kind)
      (match field-kind
        [(http_types.HttpInvalidFieldName) 1]
        [(http_types.HttpLineTooLong) 5]
        [(http_types.HttpNameTooLong) 8]
        [(http_types.HttpValueTooLong) 9]
        [_ 90])]
    [(trailer.HttpResponseTrailerPolicyError policy-kind)
      (match policy-kind
        [(trailer_policy.HttpTrailerDuplicateField) 2]
        [(trailer_policy.HttpTrailerForbiddenName) 3]
        [(trailer_policy.HttpTrailerUnapprovedName) 4]
        [_ 91])]
    [(trailer.HttpResponseTrailerRetainedBytesExceeded) 6]
    [(trailer.HttpResponseTrailerSectionTooLarge) 7]
    [_ 99]))

(define (assert-error-every-split
  [wire : String]
  [limits : trailer.HttpResponseTrailerLimits]
  [expected-code : i64]
  [expected-offset : i64]
  [expected-total-consumed : i64]) : unit
  (let
    [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
    [n : i64 (string.string-length (& wire))]
    [split : i64 0]
    (while (<= split n)
      (let
        [left : (& wire bytes) (byte_buf.bytes-slice-view view 0 split)]
        [right : (& wire bytes)
          (byte_buf.bytes-slice-view view split (- n split))]
        (begin
          (match (trailer.response-trailer-parser-feed
            (new-parser-with (clone limits) (http_types.header-name-set-empty))
            left)
            [(trailer.HttpResponseTrailerFeedNeedInput next first-consumed)
              (begin
                (test.assert-i64-eq first-consumed split "error split prefix")
                (match (trailer.response-trailer-parser-feed next right)
                  [(trailer.HttpResponseTrailerFeedErr _ error second-consumed)
                    (begin
                      (test.assert-i64-eq
                        (+ first-consumed second-consumed)
                        expected-total-consumed
                        "partitioned error consumed")
                      (test.assert-i64-eq
                        (trailer-error-code (& error))
                        expected-code
                        "partitioned error kind")
                      (test.assert-i64-eq
                        error.offset
                        expected-offset
                        "partitioned error offset"))]
                  [_ (fail "partitioned invalid trailer did not fail")]))]
            [(trailer.HttpResponseTrailerFeedErr _ error consumed)
              (begin
                (test.assert-i64-eq
                  consumed
                  expected-total-consumed
                  "single-feed error consumed")
                (test.assert-i64-eq
                  (trailer-error-code (& error))
                  expected-code
                  "single-feed error kind")
                (test.assert-i64-eq
                  error.offset
                  expected-offset
                  "single-feed error offset"))]
            [_ (fail "invalid trailer completed")])
          (set! split (+ split 1))))
      unit)))

(define (assert-error-partitions) : unit
  (begin
    (assert-error-every-split
      "X-One :a\r\n\r\nSUFFIX"
      (trailer.default-response-trailer-limits)
      1
      5
      10)
    (assert-error-every-split
      "X-One:a\r\nx-one:b\r\n\r\nSUFFIX"
      (trailer.default-response-trailer-limits)
      2
      9
      18)
    (assert-error-every-split
      "Content-Length:1\r\n\r\nSUFFIX"
      (trailer.default-response-trailer-limits)
      3
      0
      18)
    (assert-error-every-split
      "X-Other:no\r\n\r\nSUFFIX"
      (trailer.default-response-trailer-limits)
      4
      0
      12)
    (assert-error-every-split
      "X-One:a\r\nSUFFIX"
      (trailer.HttpResponseTrailerLimits 64 6 4 6 6 32)
      5
      6
      7)
    (assert-error-every-split
      "X-One:a\r\n\r\nSUFFIX"
      (trailer.HttpResponseTrailerLimits 64 32 4 4 16 32)
      8
      4
      9)
    (assert-error-every-split
      "X-One:ab\r\n\r\nSUFFIX"
      (trailer.HttpResponseTrailerLimits 64 32 4 16 1 32)
      9
      7
      10)
    (assert-error-every-split
      "X-One:ab\r\n\r\nSUFFIX"
      (trailer.HttpResponseTrailerLimits 64 32 4 16 16 6)
      6
      0
      10)
    (assert-error-every-split
      "X-One:\r\n\r\nSUFFIX"
      (trailer.HttpResponseTrailerLimits 8 6 2 5 1 5)
      7
      8
      9)))

(define (assert-declaration-policy-cross-product) : unit
  (begin
    (let
      [declared : http_types.HttpHeaderNameSet
        (declared-add (http_types.header-name-set-empty) "x-one")]
      [wire : String "X-One: yes\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed
        (new-parser-with (trailer.default-response-trailer-limits) declared)
        view)
        [(trailer.HttpResponseTrailerFeedComplete _ _) unit]
        [_ (fail "approved declared response trailer")]))
    (let
      [wire : String "X-One: yes\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedComplete _ _) unit]
        [_ (fail "approved undeclared response trailer")]))
    (let
      [declared : http_types.HttpHeaderNameSet
        (declared-add (http_types.header-name-set-empty) "x-other")]
      [wire : String "X-Other: no\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed
        (new-parser-with (trailer.default-response-trailer-limits) declared)
        view)
        [(trailer.HttpResponseTrailerFeedErr _ error _)
          (match error.kind
            [(trailer.HttpResponseTrailerPolicyError policy-kind)
              (match policy-kind
                [(trailer_policy.HttpTrailerUnapprovedName) unit]
                [_ (fail "declared unapproved policy kind")])]
            [_ (fail "declared unapproved wrapper kind")])]
        [_ (fail "declared unapproved trailer accepted")]))
    (let
      [wire : String "X-Other: no\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedErr _ error _)
          (match error.kind
            [(trailer.HttpResponseTrailerPolicyError policy-kind)
              (match policy-kind
                [(trailer_policy.HttpTrailerUnapprovedName) unit]
                [_ (fail "undeclared unapproved policy kind")])]
            [_ (fail "undeclared unapproved wrapper kind")])]
        [_ (fail "undeclared unapproved trailer accepted")]))
    (let
      [declared : http_types.HttpHeaderNameSet
        (declared-add (http_types.header-name-set-empty) "content-length")]
      [wire : String "Content-Length: 1\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed
        (new-parser-with (trailer.default-response-trailer-limits) declared)
        view)
        [(trailer.HttpResponseTrailerFeedErr _ error _)
          (match error.kind
            [(trailer.HttpResponseTrailerPolicyError policy-kind)
              (match policy-kind
                [(trailer_policy.HttpTrailerForbiddenName) unit]
                [_ (fail "forbidden declared policy kind")])]
            [_ (fail "forbidden declared wrapper kind")])]
        [_ (fail "declaration granted forbidden trailer authority")]))))

(define (assert-duplicate-and-malformed) : unit
  (begin
    (let
      [wire : String "X-One:a\r\nx-one:b\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedErr _ error _)
          (begin
            (test.assert-i64-eq error.field-index 1 "duplicate trailer index")
            (match error.kind
              [(trailer.HttpResponseTrailerPolicyError policy-kind)
                (match policy-kind
                  [(trailer_policy.HttpTrailerDuplicateField) unit]
                  [_ (fail "duplicate trailer policy kind")])]
              [_ (fail "duplicate trailer wrapper kind")]))]
        [_ (fail "at-most-once trailer repeated")]))
    (let
      [wire : String " X-One:a\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedErr terminal error consumed)
          (begin
            (test.assert-i64-eq
              consumed
              (string.string-length (& wire))
              "malformed trailer line consumed")
            (match error.kind
              [(trailer.HttpResponseTrailerFieldError field-kind)
                (match field-kind
                  [(http_types.HttpObsoleteLineFold) unit]
                  [_ (fail "obsolete trailer fold kind")])]
              [_ (fail "obsolete trailer fold wrapper")])
            (let
              [empty : String ""]
              [empty-view : (& empty bytes) (byte_buf.str-as-bytes (& empty))]
              (match (trailer.response-trailer-parser-feed terminal empty-view)
                [(trailer.HttpResponseTrailerFeedErr
                    _
                    repeated
                    repeated-consumed)
                  (begin
                    (test.assert-i64-eq
                      repeated-consumed
                      0
                      "failed terminal stable")
                    (test.assert-i64-eq
                      repeated.offset
                      error.offset
                      "failed terminal offset stable"))]
                [_ (fail "failed parser did not retain terminal result")])))]
        [_ (fail "obsolete trailer fold accepted")]))
    (let
      [wire : String "X-One :a\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedErr _ error _)
          (match error.kind
            [(trailer.HttpResponseTrailerFieldError field-kind)
              (match field-kind
                [(http_types.HttpInvalidFieldName) unit]
                [_ (fail "whitespace-before-colon field kind")])]
            [_ (fail "whitespace-before-colon wrapper")])]
        [_ (fail "whitespace before trailer colon accepted")]))
    (let
      [wire : String "\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedErr _ error consumed)
          (begin
            (test.assert-i64-eq consumed 1 "bare LF consumed")
            (match error.kind
              [(trailer.HttpResponseTrailerFieldError field-kind)
                (match field-kind
                  [(http_types.HttpBareLineFeed) unit]
                  [_ (fail "bare LF field kind")])]
              [_ (fail "bare LF wrapper")]))]
        [_ (fail "bare LF trailer accepted")]))))

(define (assert-limits) : unit
  (begin
    (match (trailer.response-trailer-parser-new
      (trailer.HttpResponseTrailerLimits 1 1 1 1 1 1)
      (sample-policy)
      (http_types.header-name-set-empty))
      [(trailer.HttpResponseTrailerParserNewErr error)
        (begin
          (test.assert-false error.poison-connection "invalid limits are local")
          (match error.kind
            [(trailer.HttpResponseTrailerInvalidLimits) unit]
            [_ (fail "invalid trailer limit kind")]))]
      [_ (fail "invalid trailer limits accepted")])
    (let
      [limits : trailer.HttpResponseTrailerLimits
        (trailer.HttpResponseTrailerLimits 8 6 2 5 1 5)]
      [wire : String "X-One:\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed
        (new-parser-with limits (http_types.header-name-set-empty))
        view)
        [(trailer.HttpResponseTrailerFeedErr _ error consumed)
          (begin
            (test.assert-i64-eq consumed 9 "section cap failing byte consumed")
            (test.assert-i64-eq error.offset 8 "section cap offset")
            (match error.kind
              [(trailer.HttpResponseTrailerSectionTooLarge) unit]
              [_ (fail "section cap kind")]))]
        [_ (fail "trailer section cap exceeded")]))
    (let
      [limits : trailer.HttpResponseTrailerLimits
        (trailer.HttpResponseTrailerLimits 64 32 4 16 16 6)]
      [exact : String "X-One:a\r\n\r\n"]
      [over : String "X-One:ab\r\n\r\n"]
      [exact-view : (& exact bytes) (byte_buf.str-as-bytes (& exact))]
      [over-view : (& over bytes) (byte_buf.str-as-bytes (& over))]
      (begin
        (match (trailer.response-trailer-parser-feed
          (new-parser-with (clone limits) (http_types.header-name-set-empty))
          exact-view)
          [(trailer.HttpResponseTrailerFeedComplete _ _) unit]
          [_ (fail "exact retained trailer cap rejected")])
        (match (trailer.response-trailer-parser-feed
          (new-parser-with limits (http_types.header-name-set-empty))
          over-view)
          [(trailer.HttpResponseTrailerFeedErr _ error _)
            (match error.kind
              [(trailer.HttpResponseTrailerRetainedBytesExceeded) unit]
              [_ (fail "retained trailer cap kind")])]
          [_ (fail "retained trailer cap exceeded")])))
    (let
      [limits : trailer.HttpResponseTrailerLimits
        (trailer.HttpResponseTrailerLimits 64 32 1 16 16 32)]
      [wire : String "X-List:a\r\nX-List:b\r\n\r\n"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed
        (new-parser-with limits (http_types.header-name-set-empty))
        view)
        [(trailer.HttpResponseTrailerFeedErr _ error _)
          (match error.kind
            [(trailer.HttpResponseTrailerPolicyError policy-kind)
              (match policy-kind
                [(trailer_policy.HttpTrailerTooManyFields) unit]
                [_ (fail "trailer count policy kind")])]
            [_ (fail "trailer count wrapper kind")])]
        [_ (fail "trailer field-count cap exceeded")]))))

(define (assert-eof-and-construction) : unit
  (begin
    (let
      [empty : String ""]
      [view : (& empty bytes) (byte_buf.str-as-bytes (& empty))]
      [parser : trailer.HttpResponseTrailerParser (new-parser)]
      [capacity : i64 (byte_buf.capacity (& parser.line))]
      (match (trailer.response-trailer-parser-feed parser view)
        [(trailer.HttpResponseTrailerFeedNeedInput next consumed)
          (begin
            (test.assert-i64-eq consumed 0 "empty trailer feed consumed")
            (test.assert-i64-eq
              (byte_buf.capacity (& next.line))
              capacity
              "empty trailer feed allocation-free")
            (match (trailer.response-trailer-parser-finish next)
              [(trailer.HttpResponseTrailerFinishErr _ error)
                (begin
                  (test.assert-i64-eq error.offset 0 "empty EOF offset")
                  (match error.kind
                    [(trailer.HttpResponseTrailerTruncatedTerminator) unit]
                    [_ (fail "empty EOF phase")]))]
              [_ (fail "empty open parser finished complete")]))]
        [_ (fail "empty feed changed parser state")]))
    (let
      [wire : String "X-One"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedNeedInput next _)
          (match (trailer.response-trailer-parser-finish next)
            [(trailer.HttpResponseTrailerFinishErr _ error)
              (begin
                (test.assert-i64-eq error.offset 5 "truncated field offset")
                (match error.kind
                  [(trailer.HttpResponseTrailerTruncatedField) unit]
                  [_ (fail "truncated field phase")]))]
            [_ (fail "truncated field completed")])]
        [_ (fail "partial field feed result")]))
    (let
      [wire : String "X-One\r"]
      [view : (& wire bytes) (byte_buf.str-as-bytes (& wire))]
      (match (trailer.response-trailer-parser-feed (new-parser) view)
        [(trailer.HttpResponseTrailerFeedNeedInput next _)
          (match (trailer.response-trailer-parser-finish next)
            [(trailer.HttpResponseTrailerFinishErr _ error)
              (begin
                (test.assert-i64-eq error.offset 5 "dangling CR offset")
                (match error.kind
                  [(trailer.HttpResponseTrailerFieldError field-kind)
                    (match field-kind
                      [(http_types.HttpBareCarriageReturn) unit]
                      [_ (fail "dangling CR field kind")])]
                  [_ (fail "dangling CR wrapper")]))]
            [_ (fail "dangling CR completed")])]
        [_ (fail "dangling CR feed result")]))
    (let
      [corrupt-policy : trailer_policy.HttpTrailerPolicy
        (trailer_policy.HttpTrailerPolicy
          (__tl_make-array trailer_policy.HttpTrailerPolicyEntry 0)
          1
          0
          (trailer_policy.default-trailer-policy-limits))]
      (match (trailer.response-trailer-parser-new
        (trailer.default-response-trailer-limits)
        corrupt-policy
        (http_types.header-name-set-empty))
        [(trailer.HttpResponseTrailerParserNewErr error)
          (match error.kind
            [(trailer.HttpResponseTrailerCorruptPolicy) unit]
            [_ (fail "corrupt trailer policy construction kind")])]
        [_ (fail "corrupt trailer policy accepted")]))
    (let
      [corrupt-declared : http_types.HttpHeaderNameSet
        (http_types.HttpHeaderNameSet (__tl_make-array byte_buf.ByteBuf 0) 1)]
      (match (trailer.response-trailer-parser-new
        (trailer.default-response-trailer-limits)
        (sample-policy)
        corrupt-declared)
        [(trailer.HttpResponseTrailerParserNewErr error)
          (match error.kind
            [(trailer.HttpResponseTrailerInvalidDeclaredNames) unit]
            [_ (fail "corrupt declared names construction kind")])]
        [_ (fail "corrupt declared names accepted")]))))

(define (main) : i64
  (begin
    (assert-valid-and-suffix)
    (assert-empty-trailers)
    (assert-valid-every-split)
    (assert-error-partitions)
    (assert-declaration-policy-cross-product)
    (assert-duplicate-and-malformed)
    (assert-limits)
    (assert-eof-and-construction)
    42))