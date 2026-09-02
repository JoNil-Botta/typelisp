;# Strict byte-oriented HTTP/1.1 head types.
;#
;# The types in this module deliberately keep protocol tokens and field values
;# as bytes. HTTP field names compare with ASCII folding, but parsing never
;# rewrites the retained spelling or value. Framing decisions are represented
;# by closed enums so body codecs do not need to inspect framing headers again.
;#
;# Header storage and byte copies allocate in the active arena. Bounds are
;# checked by the codec before any attacker-controlled buffer growth.
;#
;# Usage: `(import stdlib.net.http_types)`.
(import stdlib.byte_buf)

;: Checked HTTP method bytes.
(defstruct HttpMethod
  (bytes byte_buf.ByteBuf))

;: Checked origin-form request-target bytes.
(defstruct HttpRequestTarget
  (bytes byte_buf.ByteBuf))

;: Checked HTTP reason-phrase bytes.
(defstruct HttpReason
  (bytes byte_buf.ByteBuf))

;: Checked HTTP field-name bytes. Original ASCII case is retained.
(defstruct HttpHeaderName
  (bytes byte_buf.ByteBuf))

;: Checked HTTP field-value bytes with surrounding optional whitespace removed.
;: All other bytes retain their original spelling and order.
(defstruct HttpHeaderValue
  (bytes byte_buf.ByteBuf))

;: The strict protocol version accepted and emitted by this codec.
(defenum HttpVersion
  (Http11))

;: Three-digit HTTP response status code.
(defstruct HttpStatus
  (code i64))

;: Sensitivity metadata used to keep secret fields out of diagnostics.
(defenum HttpHeaderSensitivity
  (HttpHeaderPublic)
  (HttpHeaderSensitive))

;: Typed diagnostic disposition. `Redacted` carries no field bytes.
(defenum HttpHeaderDebugDisposition
  (HttpHeaderDebugVisible)
  (HttpHeaderDebugRedacted))

;: One checked HTTP field in wire order.
(defstruct HttpHeaderField
  (name HttpHeaderName)
  (value HttpHeaderValue)
  (sensitivity HttpHeaderSensitivity))

;: Ordered checked header collection. Only `[0, len)` is live.
(defstruct HttpHeaders
  (slots (__tl_dyn-array HttpHeaderField))
  (len i64))

;: A normalized case-insensitive set of declared trailer names. Every stored
;: name uses lowercase ASCII and appears at most once.
(defstruct HttpHeaderNameSet
  (slots (__tl_dyn-array byte_buf.ByteBuf))
  (len i64))

;: Explicit evidence that peer/config state permits HTTP/1.1 chunked request
;: transfer coding. Construction is intentionally an explicit caller action.
(defenum HttpChunkedAuthorization
  (Http11ChunkedAuthorized))

;: Caller-requested body shape before request-head validation.
(defenum HttpRequestBodyIntent
  (HttpRequestBodyNone)
  (HttpRequestBodyFixed i64)
  (HttpRequestBodyChunked HttpChunkedAuthorization))

;: Authoritative request body plan consumed by the request body encoder.
(defenum HttpRequestBodyPlan
  (HttpRequestPlanNone)
  (HttpRequestPlanFixed i64)
  (HttpRequestPlanChunked HttpChunkedAuthorization HttpHeaderNameSet))

;: Request-method semantics needed while parsing a response head.
(defenum HttpResponseRequestMethod
  (HttpResponseToHead)
  (HttpResponseToConnect)
  (HttpResponseToOther))

;: Capability controlling whether a successful CONNECT may become a tunnel.
(defenum HttpConnectCapability
  (HttpConnectDenied)
  (HttpConnectAuthorized))

;: Wire boundary retained when a transfer coding is unsupported locally.
(defenum HttpWireFraming
  (HttpWireChunked)
  (HttpWireCloseDelimited))

;: One authoritative response body decision. Unsupported transfer codings keep
;: their wire boundary so callers can close safely without choosing framing.
(defenum HttpResponseBodyPlan
  (HttpResponsePlanNone)
  (HttpResponsePlanFixed i64)
  (HttpResponsePlanChunked)
  (HttpResponsePlanCloseDelimited)
  (HttpResponsePlanUnsupportedTransferCoding HttpWireFraming)
  (HttpResponsePlanTunnel))

;: Fully checked response head. `consumed` counts bytes through the terminating
;: empty line and excludes every coalesced body byte.
(defstruct HttpResponseHead
  (version HttpVersion)
  (status HttpStatus)
  (reason HttpReason)
  (headers HttpHeaders)
  (body-plan HttpResponseBodyPlan)
  (consumed i64))

;: Fully checked serialized request head and the body plan derived with it.
(defstruct HttpSerializedRequestHead
  (bytes byte_buf.ByteBuf)
  (body-plan HttpRequestBodyPlan))

;: Configurable parser and serializer resource limits.
(defstruct HttpHeadLimits
  (max-total-bytes i64)
  (max-line-bytes i64)
  (max-fields i64)
  (max-name-bytes i64)
  (max-value-bytes i64))

;: Stable syntax, resource, and framing error categories.
(defenum HttpHeadErrorKind
  (HttpInvalidLimits)
  (HttpHeadTooLarge)
  (HttpLineTooLong)
  (HttpTooManyFields)
  (HttpNameTooLong)
  (HttpValueTooLong)
  (HttpBareCarriageReturn)
  (HttpBareLineFeed)
  (HttpNulByte)
  (HttpInvalidControlByte)
  (HttpObsoleteLineFold)
  (HttpMissingFieldColon)
  (HttpInvalidFieldName)
  (HttpNonCanonicalFieldValueWhitespace)
  (HttpInvalidMethod)
  (HttpInvalidRequestTarget)
  (HttpInvalidVersion)
  (HttpInvalidStatus)
  (HttpInvalidReason)
  (HttpMissingHost)
  (HttpDuplicateHost)
  (HttpEmptyHost)
  (HttpForbiddenConnectionHeader)
  (HttpForbiddenProxyAuthorization)
  (HttpSensitiveHeaderMustBeMarked)
  (HttpMalformedContentLength)
  (HttpContentLengthOverflow)
  (HttpConflictingContentLength)
  (HttpTransferEncodingWithContentLength)
  (HttpMalformedTransferEncoding)
  (HttpDuplicateChunkedCoding)
  (HttpChunkedCodingNotFinal)
  (HttpRequestTransferCodingUnsupported)
  (HttpRequestBodyPlanMismatch)
  (HttpTrailerWithoutChunked)
  (HttpMalformedTrailerDeclaration)
  (HttpForbiddenTrailerName)
  (HttpConnectCapabilityRequired)
  (HttpTruncatedHead)
  (HttpParserFinished))

;: Recoverable head error with a deterministic byte offset. Parsed peer input
;: sets `poison-connection` true for every syntax or framing ambiguity.
(defstruct HttpHeadError
  (kind HttpHeadErrorKind)
  (offset i64)
  (poison-connection bool))

;: Result of validating one standalone field line.
(defenum HttpFieldLineResult
  (HttpFieldLineOk HttpHeaderField)
  (HttpFieldLineErr HttpHeadError))

;: Return conservative defaults suitable for ordinary client response heads.
(define (default-head-limits) : HttpHeadLimits
  (HttpHeadLimits 65536 8192 100 1024 8192))

;: True when every configured limit is positive and internally consistent.
(define (head-limits-valid? [limits : (& limits HttpHeadLimits)]) : bool
  (and
    (> limits.max-total-bytes 0)
    (> limits.max-line-bytes 0)
    (> limits.max-fields 0)
    (> limits.max-name-bytes 0)
    (> limits.max-value-bytes 0)
    (<= limits.max-line-bytes limits.max-total-bytes)
    (<= limits.max-name-bytes limits.max-line-bytes)
    (<= limits.max-value-bytes limits.max-line-bytes)))

;: Construct a connection-poisoning peer-input error.
(define (peer-error [kind : HttpHeadErrorKind] [offset : i64]) : HttpHeadError
  (HttpHeadError kind offset true))

;: Construct a local request/configuration error that does not describe bytes
;: already accepted from a peer connection.
(define (local-error [kind : HttpHeadErrorKind] [offset : i64]) : HttpHeadError
  (HttpHeadError kind offset false))

;: Copy `count` bytes from `source` starting at `start` into owned storage.
(define (copy-byte-range
  [source : (& source bytes)]
  [start : i64]
  [count : i64]) : byte_buf.ByteBuf
  (byte_buf.from-bytes-range source start count))

;: Borrow the bytes retained by a checked method.
(define (method-bytes [method : (& source HttpMethod)]) : (& source bytes)
  (byte_buf.as-bytes (& method.bytes)))

;: Borrow the bytes retained by a checked request target.
(define (request-target-bytes [target : (& source HttpRequestTarget)]) : (&
    source
    bytes)
  (byte_buf.as-bytes (& target.bytes)))

;: Borrow the bytes retained by a checked reason phrase.
(define (reason-bytes [reason : (& source HttpReason)]) : (& source bytes)
  (byte_buf.as-bytes (& reason.bytes)))

;: Borrow the original bytes retained by a checked field name.
(define (header-name-bytes [name : (& source HttpHeaderName)]) : (&
    source
    bytes)
  (byte_buf.as-bytes (& name.bytes)))

;: Borrow the original bytes retained by a checked field value.
(define (header-value-bytes [value : (& source HttpHeaderValue)]) : (&
    source
    bytes)
  (byte_buf.as-bytes (& value.bytes)))

;: Return the diagnostic disposition without copying or exposing field bytes.
(define (header-debug-disposition [field : (& field HttpHeaderField)]) : HttpHeaderDebugDisposition
  (match field.sensitivity
    [(HttpHeaderPublic) (HttpHeaderDebugVisible)]
    [(HttpHeaderSensitive) (HttpHeaderDebugRedacted)]))

;: Return an empty ordered header collection.
(define (headers-empty) : HttpHeaders
  (HttpHeaders (__tl_make-array HttpHeaderField 4) 0))

;: Append one field through a mutable collection reference, growing
;: geometrically while preserving every live field.
(define (headers-push!
  [headers : (&mut headers HttpHeaders)]
  [field : HttpHeaderField]) : unit
  (let
    [old-len : i64 headers.len]
    [capacity : i64 (array-length headers.slots)]
    (begin
      (if (>= old-len capacity)
        (let
          [next-capacity : i64
            (if (< capacity 4)
              4
              (if (> capacity 4611686018427387903)
                (+ old-len 1)
                (* capacity 2)))]
          [slots : (__tl_dyn-array HttpHeaderField)
            (__tl_make-array HttpHeaderField next-capacity)]
          [index : i64 0]
          (begin
            (while (< index old-len)
              (begin
                (set!
                  (array-ref slots index)
                  (clone (array-ref headers.slots index)))
                (set! index (+ index 1))))
            (set! headers.slots slots)))
        unit)
      (set! (array-ref headers.slots old-len) field)
      (set! headers.len (+ old-len 1)))))

;: Append one field while preserving wire order.
(define (headers-append [headers : HttpHeaders] [field : HttpHeaderField]) : HttpHeaders
  (begin
    (headers-push! (&mut headers) field)
    headers))

;: Number of fields in an ordered header collection.
(define (headers-len [headers : (& headers HttpHeaders)]) : i64
  headers.len)

;: Borrow field `index`. Callers must first establish `0 <= index < len`.
(define (headers-ref [headers : (& source HttpHeaders)] [index : i64]) : (&
    source
    HttpHeaderField)
  (& (array-ref headers.slots index)))

;: Fold one ASCII uppercase byte to lowercase; other bytes are unchanged.
(define (ascii-lower [byte : u8]) : u8
  (let
    [code : i64 (cast byte : i64)]
    (if (and (>= code 65) (<= code 90))
      (cast (+ code 32) : u8)
      byte)))

;: True when two byte views are equal under ASCII case folding.
(define (bytes-eq-ascii-case [left : (& left bytes)] [right : (& right bytes)]) : bool
  (let
    [n : i64 (byte_buf.bytes-length left)]
    [index : i64 0]
    [same : bool (= n (byte_buf.bytes-length right))]
    (begin
      (while (and same (< index n))
        (begin
          (if (!=
            (ascii-lower (byte_buf.bytes-ref left index))
            (ascii-lower (byte_buf.bytes-ref right index)))
            (set! same false)
            unit)
          (set! index (+ index 1))))
      same)))

;: True when a checked name equals the supplied ASCII spelling, ignoring case.
(define (header-name-eq
  [name : (& name HttpHeaderName)]
  [spelling : (& spelling bytes)]) : bool
  (let
    [actual : (& name bytes) (header-name-bytes name)]
    (bytes-eq-ascii-case actual spelling)))

;: Find the first matching header index, or `-1` when absent.
(define (headers-find
  [headers : (& headers HttpHeaders)]
  [name : (& name bytes)]) : i64
  (let
    [index : i64 0]
    [found : i64 -1]
    (begin
      (while (and (< index headers.len) (< found 0))
        (let
          [field : (& headers HttpHeaderField)
            (& (array-ref headers.slots index))]
          (begin
            (if (header-name-eq (& field.name) name)
              (set! found index)
              unit)
            (set! index (+ index 1)))))
      found)))

;: Count matching fields using ASCII case-insensitive name comparison.
(define (headers-count
  [headers : (& headers HttpHeaders)]
  [name : (& name bytes)]) : i64
  (let
    [index : i64 0]
    [count : i64 0]
    (begin
      (while (< index headers.len)
        (let
          [field : (& headers HttpHeaderField)
            (& (array-ref headers.slots index))]
          (begin
            (if (header-name-eq (& field.name) name)
              (set! count (+ count 1))
              unit)
            (set! index (+ index 1)))))
      count)))

;: Return an empty normalized name set.
(define (header-name-set-empty) : HttpHeaderNameSet
  (HttpHeaderNameSet (__tl_make-array byte_buf.ByteBuf 0) 0))

;: True when the normalized set contains `name`, using ASCII folding.
(define (header-name-set-contains?
  [set : (& set HttpHeaderNameSet)]
  [name : (& name bytes)]) : bool
  (let
    [index : i64 0]
    [found : bool false]
    (begin
      (while (and (< index set.len) (not found))
        (let
          [stored : (& set byte_buf.ByteBuf) (& (array-ref set.slots index))]
          [stored-view : (& set bytes) (byte_buf.as-bytes stored)]
          (begin
            (if (bytes-eq-ascii-case stored-view name)
              (set! found true)
              unit)
            (set! index (+ index 1)))))
      found)))

;: Add `name` in normalized lowercase form, preserving first declaration order.
(define (header-name-set-add [set : HttpHeaderNameSet] [name : (& name bytes)]) : HttpHeaderNameSet
  (if (header-name-set-contains? (& set) name)
    set
    (let
      [old-len : i64 set.len]
      [slots : (__tl_dyn-array byte_buf.ByteBuf)
        (__tl_make-array byte_buf.ByteBuf (+ old-len 1))]
      [index : i64 0]
      [normalized : byte_buf.ByteBuf
        (byte_buf.with-capacity (byte_buf.bytes-length name))]
      (begin
        (while (< index old-len)
          (begin
            (set! (array-ref slots index) (array-ref set.slots index))
            (set! index (+ index 1))))
        (set! index 0)
        (while (< index (byte_buf.bytes-length name))
          (begin
            (set!
              normalized
              (byte_buf.push
                normalized
                (ascii-lower (byte_buf.bytes-ref name index))))
            (set! index (+ index 1))))
        (set! (array-ref slots old-len) normalized)
        (HttpHeaderNameSet slots (+ old-len 1))))))

;: Number of names in a normalized trailer declaration set.
(define (header-name-set-len [set : (& set HttpHeaderNameSet)]) : i64
  set.len)

;: Borrow one normalized name. Callers must first establish a valid index.
(define (header-name-set-ref [set : (& source HttpHeaderNameSet)] [index : i64]) : (&
    source
    bytes)
  (byte_buf.as-bytes (& (array-ref set.slots index))))

;: True for RFC token (`tchar`) bytes.
(define (token-byte? [byte : u8]) : bool
  (let
    [code : i64 (cast byte : i64)]
    (or
      (and (>= code 48) (<= code 57))
      (and (>= code 65) (<= code 90))
      (and (>= code 97) (<= code 122))
      (= code 33)
      (= code 35)
      (= code 36)
      (= code 37)
      (= code 38)
      (= code 39)
      (= code 42)
      (= code 43)
      (= code 45)
      (= code 46)
      (= code 94)
      (= code 95)
      (= code 96)
      (= code 124)
      (= code 126))))

;: Validate and copy one header field line without its CRLF. The result stores
;: trimmed field-value bytes, preserves their remaining octets, and reports
;: offsets relative to the enclosing input using `base-offset`.
(define (validate-field-line
  [line : (& line bytes)]
  [base-offset : i64]
  [limits : (& limits HttpHeadLimits)]
  [sensitivity : HttpHeaderSensitivity]) : HttpFieldLineResult
  (let
    [line-len : i64 (byte_buf.bytes-length line)]
    [index : i64 0]
    [colon : i64 -1]
    [bad-offset : i64 -1]
    (cond
      [(not (head-limits-valid? limits))
        (HttpFieldLineErr (peer-error (HttpInvalidLimits) base-offset))]
      [(> line-len limits.max-line-bytes)
        (HttpFieldLineErr
          (peer-error (HttpLineTooLong) (+ base-offset limits.max-line-bytes)))]
      [(= line-len 0)
        (HttpFieldLineErr (peer-error (HttpMissingFieldColon) base-offset))]
      [(let
          [first : i64 (cast (byte_buf.bytes-ref line 0) : i64)]
          (or (= first 32) (= first 9)))
        (HttpFieldLineErr (peer-error (HttpObsoleteLineFold) base-offset))]
      [else
        (begin
          (while (and (< index line-len) (< colon 0) (< bad-offset 0))
            (let
              [byte : u8 (byte_buf.bytes-ref line index)]
              [code : i64 (cast byte : i64)]
              (cond
                [(= code 58) (set! colon index)]
                [(= code 0) (set! bad-offset index)]
                [(not (token-byte? byte)) (set! bad-offset index)]
                [else (set! index (+ index 1))])))
          (cond
            [(>= bad-offset 0)
              (HttpFieldLineErr
                (peer-error
                  (if (= (cast (byte_buf.bytes-ref line bad-offset) : i64) 0)
                    (HttpNulByte)
                    (HttpInvalidFieldName))
                  (+ base-offset bad-offset)))]
            [(< colon 0)
              (HttpFieldLineErr
                (peer-error (HttpMissingFieldColon) (+ base-offset line-len)))]
            [(= colon 0)
              (HttpFieldLineErr (peer-error (HttpInvalidFieldName) base-offset))]
            [(> colon limits.max-name-bytes)
              (HttpFieldLineErr
                (peer-error
                  (HttpNameTooLong)
                  (+ base-offset limits.max-name-bytes)))]
            [else
              (let
                [raw-value-start : i64 (+ colon 1)]
                [value-start : i64 raw-value-start]
                [value-end : i64 line-len]
                (begin
                  (while (and
                    (< value-start value-end)
                    (let
                      [code : i64
                        (cast (byte_buf.bytes-ref line value-start) : i64)]
                      (or (= code 32) (= code 9))))
                    (set! value-start (+ value-start 1)))
                  (while (and
                    (> value-end value-start)
                    (let
                      [code : i64
                        (cast (byte_buf.bytes-ref line (- value-end 1)) : i64)]
                      (or (= code 32) (= code 9))))
                    (set! value-end (- value-end 1)))
                  (let
                    [value-len : i64 (- value-end value-start)]
                    [scan : i64 value-start]
                    [invalid : i64 -1]
                    (begin
                      (while (and (< scan value-end) (< invalid 0))
                        (let
                          [code : i64
                            (cast (byte_buf.bytes-ref line scan) : i64)]
                          (begin
                            (if (or
                              (= code 0)
                              (= code 10)
                              (= code 13)
                              (and (< code 32) (!= code 9))
                              (= code 127))
                              (set! invalid scan)
                              unit)
                            (set! scan (+ scan 1)))))
                      (cond
                        [(> (- line-len raw-value-start) limits.max-value-bytes)
                          (HttpFieldLineErr
                            (peer-error
                              (HttpValueTooLong)
                              (+
                                raw-value-start
                                (+ base-offset limits.max-value-bytes))))]
                        [(>= invalid 0)
                          (HttpFieldLineErr
                            (peer-error
                              (if (=
                                (cast (byte_buf.bytes-ref line invalid) : i64)
                                0)
                                (HttpNulByte)
                                (HttpInvalidControlByte))
                              (+ base-offset invalid)))]
                        [else
                          (HttpFieldLineOk
                            (HttpHeaderField
                              (HttpHeaderName (copy-byte-range line 0 colon))
                              (HttpHeaderValue
                                (copy-byte-range line value-start value-len))
                              sensitivity))])))))]))])))