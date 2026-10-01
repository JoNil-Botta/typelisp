;# Strict HTTP(S) URLs and RFC 3986 URI references.
;#
;# `parse-uri-reference` splits an RFC 3986 URI reference into scheme,
;# authority, path, query and fragment before decoding anything, so a
;# percent-encoded delimiter never changes the component structure. Each
;# component is then normalized only where RFC 3986 section 6.2.2 allows it
;# without changing its meaning: scheme and host case, percent-encoding hex
;# case, and decoding of percent-encoded unreserved bytes. Reserved
;# percent-encoded bytes stay encoded, and nothing is decoded twice.
;#
;# The authority grammar is deliberately stricter than RFC 3986:
;#
;# - userinfo is rejected (`UrlUserinfo`); errors never carry its bytes;
;# - a registered name must be an ASCII DNS name (letters, digits, `-` and
;#   non-empty `.`-separated labels of at most 63 bytes), returned lowercase.
;#   Non-ASCII or percent-encoded non-ASCII input is `UrlInternationalizedHost`
;#   (IDNA conversion is a separate layer); other percent-encodings are
;#   rejected;
;# - a name whose last label is numeric (all digits, or `0x` followed only by
;#   hex digits) must be a strict dotted-quad IPv4 address, so `1.2.3`,
;#   `0177.0.0.1` or `0x7f000001` cannot be read differently by another URL
;#   parser or address resolver;
;# - bracketed literals are IPv6 only (`stdlib.net.ip`); zone identifiers and
;#   IPvFuture are rejected;
;# - a port is 1-65535.
;#
;# Raw control bytes, space, DEL, non-ASCII bytes outside the host, backslashes,
;# malformed percent triplets and percent-encoded control bytes (including NUL)
;# are rejected everywhere, with the offset of the first offending byte.
;#
;# `uri-reference-resolve` implements RFC 3986 section 5.2 over parsed
;# references. `HttpUrl` is the HTTP policy on top: an absolute `http` or
;# `https` reference with an authority, dot segments removed, an empty path
;# spelled `/` and the port made explicit. It formats canonically and provides
;# the origin-form request target (never the fragment) and byte-stable keys for
;# the complete URL, redirect-loop identity (no fragment) and origin.
;#
;# Every length is checked against `UrlLimits` before a component is copied;
;# allocation is bounded by the input. This module performs no I/O or name
;# resolution.
;#
;# Usage: `(import stdlib.net.url)`.
(import stdlib.byte_buf)
(import stdlib.net.ip)
(import stdlib.str_cat)
(import stdlib.string)

;: Bounds checked before any component is copied. Lengths are byte counts of
;: the input text of each component.
(defstruct UrlLimits
  (max-input i64)
  (max-host i64)
  (max-path i64)
  (max-query i64)
  (max-fragment i64))

;: Default limits: 8 KiB of input and per component, and 253-byte DNS names.
(define (default-url-limits) : UrlLimits
  (UrlLimits 8192 253 8192 8192 8192))

;: Stable failure categories.
(defenum UrlErrorKind
  (UrlTooLong)
  (UrlComponentTooLong)
  (UrlInvalidByte)
  (UrlBackslash)
  (UrlBadPercentEncoding)
  (UrlEncodedControl)
  (UrlColonInFirstSegment)
  (UrlNotAbsolute)
  (UrlUnsupportedScheme)
  (UrlMissingAuthority)
  (UrlUserinfo)
  (UrlEmptyHost)
  (UrlInvalidHost)
  (UrlInternationalizedHost)
  (UrlInvalidIpv4)
  (UrlInvalidIpv6)
  (UrlIpv6Zone)
  (UrlUnsupportedIpFuture)
  (UrlInvalidPort))

;: A failure with the byte offset in the input where it was found. Errors
;: detected after parsing (the HTTP policy and resolution) use offset 0.
(defstruct UrlError
  (kind UrlErrorKind)
  (offset i64))

;: The host of an authority.
(defenum UrlHost
  ;; A lowercase ASCII DNS name.
  (UrlHostName String)
  (UrlHostIpv4 ip.Ipv4Addr)
  (UrlHostIpv6 ip.Ipv6Addr))

;: An optional component; a present component may be empty (`?` alone).
(defenum UrlPart
  (UrlPartAbsent)
  (UrlPartPresent String))

;: An RFC 3986 URI reference with normalized components. `host` and `port`
;: are meaningful only when `authority` is true; `port` is -1 when absent.
(defstruct UriReference
  (scheme UrlPart)
  (authority bool)
  (host UrlHost)
  (port i64)
  (path String)
  (query UrlPart)
  (fragment UrlPart))

;: Result of parsing or resolving a URI reference.
(defenum UriReferenceResult
  (UriReferenceOk UriReference)
  (UriReferenceErr UrlError))

;: The two schemes the HTTP policy accepts.
(defenum HttpScheme
  (HttpSchemeHttp)
  (HttpSchemeHttps))

;: An absolute HTTP(S) URL. `path` is non-empty and starts with `/`, with dot
;: segments removed; `port` is the effective port (the scheme default when the
;: input had none).
(defstruct HttpUrl
  (scheme HttpScheme)
  (host UrlHost)
  (port i64)
  (path String)
  (query UrlPart)
  (fragment UrlPart))

;: Result of parsing, validating or resolving an HTTP(S) URL.
(defenum HttpUrlResult
  (HttpUrlOk HttpUrl)
  (HttpUrlErr UrlError))

;: The HTTP origin of a URL: scheme, host and effective port.
(defstruct HttpOrigin
  (scheme HttpScheme)
  (host UrlHost)
  (port i64))

;: Normalized component text, or the first error inside the component.
(defenum UrlTextResult
  (UrlTextOk String)
  (UrlTextErr UrlError))

;: A parsed authority's host and port (-1 when absent).
(defstruct UrlAuthority
  (host UrlHost)
  (port i64))

;: A parsed authority, or the first error inside it.
(defenum UrlAuthorityResult
  (UrlAuthorityOk UrlAuthority)
  (UrlAuthorityErr UrlError))

;: A port (-1 when absent), or the error at its first bad byte.
(defenum UrlPortResult
  (UrlPortOk i64)
  (UrlPortErr UrlError))

;: An error of KIND at byte OFFSET.
(define (url-error [kind : UrlErrorKind] [offset : i64]) : UrlError
  (UrlError kind offset))

;: A stable name for an error kind, for diagnostics and tests.
(define (url-error-kind-name [kind : (& kind UrlErrorKind)]) : String
  (match kind
    [(UrlTooLong) "too-long"]
    [(UrlComponentTooLong) "component-too-long"]
    [(UrlInvalidByte) "invalid-byte"]
    [(UrlBackslash) "backslash"]
    [(UrlBadPercentEncoding) "bad-percent-encoding"]
    [(UrlEncodedControl) "encoded-control"]
    [(UrlColonInFirstSegment) "colon-in-first-segment"]
    [(UrlNotAbsolute) "not-absolute"]
    [(UrlUnsupportedScheme) "unsupported-scheme"]
    [(UrlMissingAuthority) "missing-authority"]
    [(UrlUserinfo) "userinfo"]
    [(UrlEmptyHost) "empty-host"]
    [(UrlInvalidHost) "invalid-host"]
    [(UrlInternationalizedHost) "internationalized-host"]
    [(UrlInvalidIpv4) "invalid-ipv4"]
    [(UrlInvalidIpv6) "invalid-ipv6"]
    [(UrlIpv6Zone) "ipv6-zone"]
    [(UrlUnsupportedIpFuture) "unsupported-ip-future"]
    [(UrlInvalidPort) "invalid-port"]))

;; --- byte classes -----------------------------------------------------------
;: The byte at INDEX of TEXT.
(define (url-byte [text : (& text str)] [index : i64]) : i64
  (cast (string.string-ref text index) : i64))

;: Whether B is an ASCII letter.
(define (url-alpha? [b : i64]) : bool
  (or (and (>= b 65) (<= b 90)) (and (>= b 97) (<= b 122))))

;: Whether B is an ASCII digit.
(define (url-digit? [b : i64]) : bool
  (and (>= b 48) (<= b 57)))

;: The value of the hex digit B, or -1.
(define (url-hex-value [b : i64]) : i64
  (cond
    [(url-digit? b) (- b 48)]
    [(and (>= b 65) (<= b 70)) (- b 55)]
    [(and (>= b 97) (<= b 102)) (- b 87)]
    [else -1]))

;: B, lowered when it is an ASCII uppercase letter.
(define (url-lower [b : i64]) : i64
  (if (and (>= b 65) (<= b 90))
    (+ b 32)
    b))

;: RFC 3986 unreserved: ALPHA / DIGIT / "-" / "." / "_" / "~".
(define (url-unreserved? [b : i64]) : bool
  (or (url-alpha? b) (url-digit? b) (= b 45) (= b 46) (= b 95) (= b 126)))

;: RFC 3986 sub-delims: "!" / "$" / "&" / "'" / "(" / ")" / "*" / "+" / "," /
;: ";" / "=".
(define (url-sub-delim? [b : i64]) : bool
  (or
    (= b 33)
    (= b 36)
    (= b 38)
    (= b 39)
    (= b 40)
    (= b 41)
    (= b 42)
    (= b 43)
    (= b 44)
    (= b 59)
    (= b 61)))

;: A byte a path segment may contain literally: unreserved, sub-delims, ":"
;: and "@" (pchar without pct-encoded).
(define (url-pchar? [b : i64]) : bool
  (or (url-unreserved? b) (url-sub-delim? b) (= b 58) (= b 64)))

;: BUF with byte B appended.
(define (url-push [buf : byte_buf.ByteBuf] [b : i64]) : byte_buf.ByteBuf
  (byte_buf.push buf (cast b : u8)))

;: BUF with the uppercase hex digit for VALUE (0-15) appended.
(define (url-push-hex-digit [buf : byte_buf.ByteBuf] [value : i64]) : byte_buf.ByteBuf
  (url-push
    buf
    (if (< value 10)
      (+ 48 value)
      (+ 55 value))))

;; --- component normalization --------------------------------------------------
;: Validate and normalize `text[start, end)` as a path (QUERY? false) or a query
;: or fragment (QUERY? true, which also admits "?"). Percent triplets must be
;: complete hex; they are rewritten with uppercase hex, or decoded when they
;: encode an unreserved byte. Encoded control bytes are rejected.
(define (url-normalize-component
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [query? : bool]) : UrlTextResult
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (- end start))]
    [index : i64 start]
    (begin
      (while (< index end)
        (let
          [b : i64 (url-byte text index)]
          (cond
            [(= b 37)
              (begin
                (when
                  (> (+ index 3) end)
                  (return
                    (UrlTextErr (url-error (UrlBadPercentEncoding) index))))
                (let
                  [high : i64 (url-hex-value (url-byte text (+ index 1)))]
                  [low : i64 (url-hex-value (url-byte text (+ index 2)))]
                  [decoded : i64 0]
                  (begin
                    (when
                      (or (< high 0) (< low 0))
                      (return
                        (UrlTextErr (url-error (UrlBadPercentEncoding) index))))
                    (set! decoded (+ (* high 16) low))
                    (when
                      (or (< decoded 32) (= decoded 127))
                      (return
                        (UrlTextErr (url-error (UrlEncodedControl) index))))
                    (if (url-unreserved? decoded)
                      (set! out (url-push out decoded))
                      (begin
                        (set! out (url-push out 37))
                        (set! out (url-push-hex-digit out high))
                        (set! out (url-push-hex-digit out low))))
                    (set! index (+ index 3)))))]
            [(or (url-pchar? b) (= b 47) (and query? (= b 63)))
              (begin
                (set! out (url-push out b))
                (set! index (+ index 1)))]
            [else (return (UrlTextErr (url-error (UrlInvalidByte) index)))])))
      (UrlTextOk (byte_buf.to-string out)))))

;: Normalize an optional component that starts after its one-byte delimiter at
;: DELIMITER (-1 when absent) and ends at END, within LIMIT bytes.
(define (url-normalize-part
  [text : (& text str)]
  [delimiter : i64]
  [end : i64]
  [limit : i64]) : UrlTextResult
  (if (< delimiter 0)
    (UrlTextOk "")
    (if (> (- end (+ delimiter 1)) limit)
      (UrlTextErr (url-error (UrlComponentTooLong) (+ delimiter 1 limit)))
      (url-normalize-component text (+ delimiter 1) end true))))

;; --- authority ---------------------------------------------------------------
;: Validate `text[start, end)` as a lowercase ASCII DNS name.
(define (url-parse-host-name
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [limits : UrlLimits]) : UrlAuthorityResult
  (cond
    [(= start end) (UrlAuthorityErr (url-error (UrlEmptyHost) start))]
    [(> (- end start) limits.max-host)
      (UrlAuthorityErr
        (url-error (UrlComponentTooLong) (+ start limits.max-host)))]
    [else
      (let
        [out : byte_buf.ByteBuf (byte_buf.with-capacity (- end start))]
        [index : i64 start]
        [label-start : i64 start]
        [last-label-start : i64 start]
        (begin
          (while (< index end)
            (let
              [b : i64 (url-byte text index)]
              (cond
                [(>= b 128)
                  (return
                    (UrlAuthorityErr
                      (url-error (UrlInternationalizedHost) index)))]
                ;; A complete triplet encoding a non-ASCII byte is an
                ;; internationalized name; any other "%" is not a DNS name.
                [(= b 37)
                  (let
                    [high : i64
                      (if (< (+ index 2) end)
                        (url-hex-value (url-byte text (+ index 1)))
                        -1)]
                    [low : i64
                      (if (< (+ index 2) end)
                        (url-hex-value (url-byte text (+ index 2)))
                        -1)]
                    (return
                      (UrlAuthorityErr
                        (url-error
                          (if (and (>= high 8) (>= low 0))
                            (UrlInternationalizedHost)
                            (UrlInvalidHost))
                          index))))]
                [(= b 46)
                  (begin
                    (when
                      (= index label-start)
                      (return
                        (UrlAuthorityErr (url-error (UrlInvalidHost) index))))
                    (when
                      (= (url-byte text (- index 1)) 45)
                      (return
                        (UrlAuthorityErr
                          (url-error (UrlInvalidHost) (- index 1)))))
                    (set! out (url-push out 46))
                    (set! index (+ index 1))
                    (set! label-start index)
                    (set! last-label-start index))]
                [(or (url-alpha? b) (url-digit? b) (= b 45))
                  (begin
                    (when
                      (and (= b 45) (= index label-start))
                      (return
                        (UrlAuthorityErr (url-error (UrlInvalidHost) index))))
                    (when
                      (>= (- index label-start) 63)
                      (return
                        (UrlAuthorityErr
                          (url-error (UrlComponentTooLong) index))))
                    (set! out (url-push out (url-lower b)))
                    (set! index (+ index 1)))]
                [else
                  (return (UrlAuthorityErr (url-error (UrlInvalidHost) index)))])))
          (when
            (= label-start end)
            (return (UrlAuthorityErr (url-error (UrlInvalidHost) end))))
          (when
            (= (url-byte text (- end 1)) 45)
            (return (UrlAuthorityErr (url-error (UrlInvalidHost) (- end 1)))))
          (if (url-numeric-label? text last-label-start end)
            (match (ip.parse-ipv4-range text start end)
              [(ip.Ipv4Ok address)
                (UrlAuthorityOk (UrlAuthority (UrlHostIpv4 address) -1))]
              [(ip.Ipv4Err error)
                (UrlAuthorityErr (url-error (UrlInvalidIpv4) error.offset))])
            (UrlAuthorityOk
              (UrlAuthority (UrlHostName (byte_buf.to-string out)) -1)))))]))

;: Whether `text[start, end)` is a label other URL parsers and address
;: resolvers read as an IPv4 number: all ASCII digits, or `0x`/`0X` followed
;: only by hex digits (possibly none).
(define (url-numeric-label? [text : (& text str)] [start : i64] [end : i64]) : bool
  (if (and
    (>= (- end start) 2)
    (= (url-byte text start) 48)
    (= (url-lower (url-byte text (+ start 1))) 120))
    (let
      [index : i64 (+ start 2)]
      (begin
        (while (< index end)
          (begin
            (when (< (url-hex-value (url-byte text index)) 0) (return false))
            (set! index (+ index 1))))
        true))
    (url-all-digits? text start end)))

;: Whether `text[start, end)` is non-empty and all ASCII digits.
(define (url-all-digits? [text : (& text str)] [start : i64] [end : i64]) : bool
  (let
    [index : i64 start]
    (begin
      (while (< index end)
        (begin
          (unless (url-digit? (url-byte text index)) (return false))
          (set! index (+ index 1))))
      (< start end))))

;: Parse the bracketed IPv6 literal whose "[" is at START, ending before
;: END_BRACKET.
(define (url-parse-ipv6-literal
  [text : (& text str)]
  [start : i64]
  [end-bracket : i64]) : UrlAuthorityResult
  (let
    [inner-start : i64 (+ start 1)]
    (begin
      (when
        (and
          (< inner-start end-bracket)
          (or
            (= (url-byte text inner-start) 118)
            (= (url-byte text inner-start) 86)))
        (return
          (UrlAuthorityErr (url-error (UrlUnsupportedIpFuture) inner-start))))
      (let
        [index : i64 inner-start]
        (while (< index end-bracket)
          (begin
            (when
              (= (url-byte text index) 37)
              (return (UrlAuthorityErr (url-error (UrlIpv6Zone) index))))
            (set! index (+ index 1)))))
      (if (> (- end-bracket inner-start) (ip.ipv6-max-text-bytes))
        (UrlAuthorityErr (url-error (UrlInvalidIpv6) inner-start))
        (match (ip.parse-ipv6
          (string.substring text inner-start (- end-bracket inner-start)))
          [(ip.Ipv6Ok address)
            (UrlAuthorityOk (UrlAuthority (UrlHostIpv6 address) -1))]
          [(ip.Ipv6Err error)
            (UrlAuthorityErr
              (url-error (UrlInvalidIpv6) (+ inner-start error.offset)))])))))

;: Parse the port digits `text[start, end)`; an empty port is absent.
(define (url-parse-port [text : (& text str)] [start : i64] [end : i64]) : UrlPortResult
  (if (= start end)
    (UrlPortOk -1)
    (let
      [value : i64 0]
      [index : i64 start]
      (begin
        (while (< index end)
          (let
            [b : i64 (url-byte text index)]
            (begin
              (unless
                (url-digit? b)
                (return (UrlPortErr (url-error (UrlInvalidPort) index))))
              (set! value (+ (* value 10) (- b 48)))
              (when
                (> value 65535)
                (return (UrlPortErr (url-error (UrlInvalidPort) index))))
              (set! index (+ index 1)))))
        (if (= value 0)
          (UrlPortErr (url-error (UrlInvalidPort) start))
          (UrlPortOk value))))))

;: Parse the authority `text[start, end)`.
(define (url-parse-authority
  [text : (& text str)]
  [start : i64]
  [end : i64]
  [limits : UrlLimits]) : UrlAuthorityResult
  (let
    [index : i64 start]
    (begin
      ;; Userinfo is rejected before any host parsing, at its "@".
      (while (< index end)
        (begin
          (when
            (= (url-byte text index) 64)
            (return (UrlAuthorityErr (url-error (UrlUserinfo) index))))
          (set! index (+ index 1))))
      (let
        [host-end : i64 end]
        [host : UrlAuthorityResult
          (UrlAuthorityErr (url-error (UrlEmptyHost) start))]
        (begin
          (if (and (< start end) (= (url-byte text start) 91))
            (let
              [close : i64 (url-find text (+ start 1) end 93)]
              (begin
                (when
                  (< close 0)
                  (return (UrlAuthorityErr (url-error (UrlInvalidIpv6) end))))
                ;; A malformed literal is reported before anything after "]".
                (match (url-parse-ipv6-literal text start close)
                  [(UrlAuthorityErr error) (return (UrlAuthorityErr error))]
                  [(UrlAuthorityOk literal)
                    (set! host (UrlAuthorityOk literal))])
                (set! host-end (+ close 1))
                (when
                  (and (< host-end end) (!= (url-byte text host-end) 58))
                  (return
                    (UrlAuthorityErr (url-error (UrlInvalidHost) host-end))))))
            (begin
              (set! host-end (url-find text start end 58))
              (when (< host-end 0) (set! host-end end))
              (set! host (url-parse-host-name text start host-end limits))))
          (match host
            [(UrlAuthorityOk authority)
              (if (< host-end end)
                (match (url-parse-port text (+ host-end 1) end)
                  [(UrlPortOk port)
                    (UrlAuthorityOk (UrlAuthority authority.host port))]
                  [(UrlPortErr error) (UrlAuthorityErr error)])
                (UrlAuthorityOk authority))]
            [(UrlAuthorityErr error) (UrlAuthorityErr error)]))))))

;: The first index of byte B in `text[start, end)`, or -1.
(define (url-find [text : (& text str)] [start : i64] [end : i64] [b : i64]) : i64
  (let
    [index : i64 start]
    (begin
      (while (< index end)
        (begin
          (when (= (url-byte text index) b) (return index))
          (set! index (+ index 1))))
      -1)))

;; --- references --------------------------------------------------------------
;: The end of the scheme when TEXT starts with `scheme ":"`, else -1.
(define (url-scheme-end [text : (& text str)] [end : i64]) : i64
  (if (or (= end 0) (not (url-alpha? (url-byte text 0))))
    -1
    (let
      [index : i64 1]
      (begin
        (while (< index end)
          (let
            [b : i64 (url-byte text index)]
            (cond
              [(= b 58) (return index)]
              [(or (url-alpha? b) (url-digit? b) (= b 43) (= b 45) (= b 46))
                (set! index (+ index 1))]
              [else (return -1)])))
        -1))))

;: Parse an RFC 3986 URI reference (absolute or relative) into normalized
;: components. Dot segments are kept: they matter when resolving a relative
;: reference.
(define (parse-uri-reference [text : (& text str)] [limits : UrlLimits]) : UriReferenceResult
  (let
    [n : i64 (string.string-length text)]
    (begin
      (when
        (> n limits.max-input)
        (return (UriReferenceErr (url-error (UrlTooLong) limits.max-input))))
      ;; Bytes no component may contain, found in input order.
      (let
        [index : i64 0]
        (while (< index n)
          (let
            [b : i64 (url-byte text index)]
            (begin
              (when
                (= b 92)
                (return (UriReferenceErr (url-error (UrlBackslash) index))))
              (when
                (or (<= b 32) (= b 127))
                (return (UriReferenceErr (url-error (UrlInvalidByte) index))))
              (set! index (+ index 1))))))
      (let
        [fragment-at : i64 (url-find text 0 n 35)]
        [hier-end-0 : i64
          (if (< fragment-at 0)
            n
            fragment-at)]
        [query-at : i64 (url-find text 0 hier-end-0 63)]
        [hier-end : i64
          (if (< query-at 0)
            hier-end-0
            query-at)]
        [scheme-end : i64 (url-scheme-end text hier-end)]
        [scheme : UrlPart (UrlPartAbsent)]
        [cursor : i64 0]
        [authority : bool false]
        [host : UrlHost (UrlHostName "")]
        [port : i64 -1]
        (begin
          (if (>= scheme-end 0)
            (let
              [out : byte_buf.ByteBuf (byte_buf.with-capacity scheme-end)]
              [index : i64 0]
              (begin
                (while (< index scheme-end)
                  (begin
                    (set! out (url-push out (url-lower (url-byte text index))))
                    (set! index (+ index 1))))
                (set! scheme (UrlPartPresent (byte_buf.to-string out)))
                (set! cursor (+ scheme-end 1))))
            ;; A relative-path reference cannot have ":" in its first segment.
            (let
              [first-slash : i64 (url-find text 0 hier-end 47)]
              [colon : i64
                (url-find
                  text
                  0
                  (if (< first-slash 0)
                    hier-end
                    first-slash)
                  58)]
              (when
                (>= colon 0)
                (return
                  (UriReferenceErr (url-error (UrlColonInFirstSegment) colon))))))
          (when
            (and
              (<= (+ cursor 2) hier-end)
              (= (url-byte text cursor) 47)
              (= (url-byte text (+ cursor 1)) 47))
            (let
              [authority-start : i64 (+ cursor 2)]
              [authority-end-0 : i64
                (url-find text authority-start hier-end 47)]
              [authority-end : i64
                (if (< authority-end-0 0)
                  hier-end
                  authority-end-0)]
              (match (url-parse-authority
                text
                authority-start
                authority-end
                limits)
                [(UrlAuthorityOk parsed)
                  (begin
                    (set! authority true)
                    (set! host parsed.host)
                    (set! port parsed.port)
                    (set! cursor authority-end))]
                [(UrlAuthorityErr error) (return (UriReferenceErr error))])))
          (when
            (> (- hier-end cursor) limits.max-path)
            (return
              (UriReferenceErr
                (url-error (UrlComponentTooLong) (+ cursor limits.max-path)))))
          (match (url-normalize-component text cursor hier-end false)
            [(UrlTextErr error) (UriReferenceErr error)]
            [(UrlTextOk path)
              (match (url-normalize-part
                text
                query-at
                hier-end-0
                limits.max-query)
                [(UrlTextErr error) (UriReferenceErr error)]
                [(UrlTextOk query)
                  (match (url-normalize-part
                    text
                    fragment-at
                    n
                    limits.max-fragment)
                    [(UrlTextErr error) (UriReferenceErr error)]
                    [(UrlTextOk fragment)
                      (UriReferenceOk
                        (UriReference
                          scheme
                          authority
                          host
                          port
                          path
                          (if (< query-at 0)
                            (UrlPartAbsent)
                            (UrlPartPresent query))
                          (if (< fragment-at 0)
                            (UrlPartAbsent)
                            (UrlPartPresent fragment))))])])]))))))

;; --- dot segments and resolution ----------------------------------------------
;: Whether TEXT has PREFIX at START.
(define (url-starts-with?
  [text : (& text str)]
  [start : i64]
  [prefix : (& prefix str)]) : bool
  (let
    [n : i64 (string.string-length prefix)]
    [index : i64 0]
    (begin
      (when (> (+ start n) (string.string-length text)) (return false))
      (while (< index n)
        (begin
          (unless
            (= (url-byte text (+ start index)) (url-byte prefix index))
            (return false))
          (set! index (+ index 1))))
      true)))

;: Remove the last segment and its preceding "/" (if any) from OUT.
(define (url-pop-segment [out : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (let
    [n : i64 (byte_buf.len (& out))]
    [cut : i64 0]
    [index : i64 (- n 1)]
    (begin
      (while (>= index 0)
        (begin
          (when
            (= (cast (byte_buf.ref (& out) index) : i64) 47)
            (begin
              (set! cut index)
              (set! index -1)))
          (set! index (- index 1))))
      (byte_buf.from-array-prefix (byte_buf.to-array out) cut))))

;: RFC 3986 section 5.2.4 remove_dot_segments.
(define (remove-dot-segments [path : (& path str)]) : String
  (let
    [n : i64 (string.string-length path)]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity n)]
    [index : i64 0]
    (begin
      (while (< index n)
        (cond
          ;; A. "../" or "./" prefix
          [(url-starts-with? path index "../") (set! index (+ index 3))]
          [(url-starts-with? path index "./") (set! index (+ index 2))]
          ;; B. "/./" or "/." at the end
          [(url-starts-with? path index "/./") (set! index (+ index 2))]
          [(and (url-starts-with? path index "/.") (= (+ index 2) n))
            (begin
              (set! out (url-push out 47))
              (set! index n))]
          ;; C. "/../" or "/.." at the end
          [(url-starts-with? path index "/../")
            (begin
              (set! out (url-pop-segment out))
              (set! index (+ index 3)))]
          [(and (url-starts-with? path index "/..") (= (+ index 3) n))
            (begin
              (set! out (url-pop-segment out))
              (set! out (url-push out 47))
              (set! index n))]
          ;; D. "." or ".." alone
          [(and (url-starts-with? path index ".") (= (+ index 1) n))
            (set! index n)]
          [(and (url-starts-with? path index "..") (= (+ index 2) n))
            (set! index n)]
          ;; E. move the first segment, with its leading "/", to the output
          [else
            (begin
              (when
                (= (url-byte path index) 47)
                (begin
                  (set! out (url-push out 47))
                  (set! index (+ index 1))))
              (while (and (< index n) (!= (url-byte path index) 47))
                (begin
                  (set! out (url-push out (url-byte path index)))
                  (set! index (+ index 1)))))]))
      (byte_buf.to-string out))))

;: RFC 3986 section 5.2.3 merge of a relative path onto BASE.
(define (url-merge-paths [base : (& base UriReference)] [path : (& path str)]) : String
  (if (and base.authority (= (string.string-length base.path) 0))
    (str_cat.str-cat "/" path)
    (let
      [n : i64 (string.string-length base.path)]
      [cut : i64 -1]
      [index : i64 0]
      (begin
        (while (< index n)
          (begin
            (when (= (url-byte base.path index) 47) (set! cut index))
            (set! index (+ index 1))))
        (if (< cut 0)
          (string.copy path)
          (let
            [prefix : String (string.substring base.path 0 (+ cut 1))]
            (str_cat.str-cat prefix path)))))))

;: A copy of a borrowed optional component.
(define (url-part-copy [part : (& part UrlPart)]) : UrlPart
  (match part
    [(UrlPartAbsent) (UrlPartAbsent)]
    [(UrlPartPresent text) (UrlPartPresent (string.copy text))]))

;: A copy of a borrowed host.
(define (url-host-copy [host : (& host UrlHost)]) : UrlHost
  (match host
    [(UrlHostName name) (UrlHostName (string.copy name))]
    [(UrlHostIpv4 address) (UrlHostIpv4 (ip.Ipv4Addr (ip.ipv4-octets address)))]
    [(UrlHostIpv6 address) (UrlHostIpv6 (ip.Ipv6Addr (ip.ipv6-octets address)))]))

;: Whether an optional component is present.
(define (url-part-present? [part : (& part UrlPart)]) : bool
  (match part
    [(UrlPartAbsent) false]
    [(UrlPartPresent _) true]))

;: Resolve REFERENCE against the absolute BASE (RFC 3986 section 5.2.2, strict
;: parser: a reference with a scheme is used as is).
(define (uri-reference-resolve
  [base : (& base UriReference)]
  [reference : (& reference UriReference)]) : UriReferenceResult
  (if (not (url-part-present? (& base.scheme)))
    (UriReferenceErr (url-error (UrlNotAbsolute) 0))
    (UriReferenceOk
      (cond
        [(url-part-present? (& reference.scheme))
          (UriReference
            (url-part-copy (& reference.scheme))
            reference.authority
            (url-host-copy (& reference.host))
            reference.port
            (remove-dot-segments reference.path)
            (url-part-copy (& reference.query))
            (url-part-copy (& reference.fragment)))]
        [reference.authority
          (UriReference
            (url-part-copy (& base.scheme))
            true
            (url-host-copy (& reference.host))
            reference.port
            (remove-dot-segments reference.path)
            (url-part-copy (& reference.query))
            (url-part-copy (& reference.fragment)))]
        [(= (string.string-length reference.path) 0)
          (UriReference
            (url-part-copy (& base.scheme))
            base.authority
            (url-host-copy (& base.host))
            base.port
            (string.copy base.path)
            (if (url-part-present? (& reference.query))
              (url-part-copy (& reference.query))
              (url-part-copy (& base.query)))
            (url-part-copy (& reference.fragment)))]
        [else
          (UriReference
            (url-part-copy (& base.scheme))
            base.authority
            (url-host-copy (& base.host))
            base.port
            (if (= (url-byte reference.path 0) 47)
              (remove-dot-segments reference.path)
              (remove-dot-segments (url-merge-paths base reference.path)))
            (url-part-copy (& reference.query))
            (url-part-copy (& reference.fragment)))]))))

;; --- formatting ----------------------------------------------------------------
;: The host as it appears in an authority: a DNS name, dotted IPv4, or
;: bracketed canonical IPv6.
(define (url-host-to-string [host : (& host UrlHost)]) : String
  (match host
    [(UrlHostName name) (string.copy name)]
    [(UrlHostIpv4 address) (ip.ipv4-to-string (& address))]
    [(UrlHostIpv6 address)
      (str_cat.str-cat "[" (ip.ipv6-to-string (& address)) "]")]))

;: OUT followed by DELIMITER and the text of PART when PART is present.
(define (url-append-part
  [out : String]
  [delimiter : (& delimiter str)]
  [part : (& part UrlPart)]) : String
  (match part
    [(UrlPartAbsent) out]
    [(UrlPartPresent text) (str_cat.str-cat out delimiter text)]))

;: The `//host[:port]` authority text of REFERENCE, or "" without one.
(define (url-authority-text [reference : (& reference UriReference)]) : String
  (if reference.authority
    (let
      [host : String (url-host-to-string (& reference.host))]
      (if (>= reference.port 0)
        (let
          [port : String (string.int->string reference.port)]
          (str_cat.str-cat "//" host ":" port))
        (str_cat.str-cat "//" host)))
    ""))

;: The five parts of a reference spelling, joined.
(define (url-compose
  [scheme : (& scheme str)]
  [authority : (& authority str)]
  [path : (& path str)]
  [query : (& query str)]
  [fragment : (& fragment str)]) : String
  (str_cat.str-cat scheme authority path query fragment))

;: Recompose a reference (RFC 3986 section 5.3).
(define (uri-reference-to-string [reference : (& reference UriReference)]) : String
  (let
    [scheme : String
      (match reference.scheme
        [(UrlPartAbsent) ""]
        [(UrlPartPresent name) (str_cat.str-cat name ":")])]
    [authority : String (url-authority-text reference)]
    [query : String (url-append-part "" "?" (& reference.query))]
    [fragment : String (url-append-part "" "#" (& reference.fragment))]
    (url-compose scheme authority reference.path query fragment)))

;; --- HTTP policy ---------------------------------------------------------------
;: The lowercase scheme name, `http` or `https`.
(define (http-scheme-name [scheme : (& scheme HttpScheme)]) : String
  (match scheme
    [(HttpSchemeHttp) "http"]
    [(HttpSchemeHttps) "https"]))

;: A copy of a borrowed scheme.
(define (http-scheme-copy [scheme : (& scheme HttpScheme)]) : HttpScheme
  (match scheme
    [(HttpSchemeHttp) (HttpSchemeHttp)]
    [(HttpSchemeHttps) (HttpSchemeHttps)]))

;: The port a URL without an explicit port uses: 80 for `http`, 443 for
;: `https`.
(define (http-default-port [scheme : (& scheme HttpScheme)]) : i64
  (match scheme
    [(HttpSchemeHttp) 80]
    [(HttpSchemeHttps) 443]))

;: Apply the HTTP policy to a parsed or resolved reference: an `http` or
;: `https` scheme, an authority, dot segments removed and an empty path
;: spelled `/`.
(define (http-url-from-reference [reference : (& reference UriReference)]) : HttpUrlResult
  (let
    [scheme : HttpScheme (HttpSchemeHttp)]
    (begin
      (match reference.scheme
        [(UrlPartAbsent) (return (HttpUrlErr (url-error (UrlNotAbsolute) 0)))]
        [(UrlPartPresent name)
          (cond
            [(string.eq name "http") (set! scheme (HttpSchemeHttp))]
            [(string.eq name "https") (set! scheme (HttpSchemeHttps))]
            [else (return (HttpUrlErr (url-error (UrlUnsupportedScheme) 0)))])])
      (unless
        reference.authority
        (return (HttpUrlErr (url-error (UrlMissingAuthority) 0))))
      (let
        [path : String (remove-dot-segments reference.path)]
        (HttpUrlOk
          (HttpUrl
            scheme
            (url-host-copy (& reference.host))
            (if (< reference.port 0)
              (http-default-port (& scheme))
              reference.port)
            (if (= (string.string-length path) 0)
              "/"
              path)
            (url-part-copy (& reference.query))
            (url-part-copy (& reference.fragment))))))))

;: Parse a strict absolute `http` or `https` URL.
(define (parse-http-url [text : (& text str)] [limits : UrlLimits]) : HttpUrlResult
  (match (parse-uri-reference text limits)
    [(UriReferenceErr error)
      (if (match error.kind
        [(UrlColonInFirstSegment) true]
        [_ false])
        (HttpUrlErr (url-error (UrlNotAbsolute) 0))
        (HttpUrlErr error))]
    [(UriReferenceOk reference) (http-url-from-reference (& reference))]))

;: The URL as a reference, for use as a resolution base. The port is written
;: only when it is not the scheme default.
(define (http-url-to-reference [url : (& url HttpUrl)]) : UriReference
  (UriReference
    (UrlPartPresent (http-scheme-name (& url.scheme)))
    true
    (url-host-copy (& url.host))
    (if (= url.port (http-default-port (& url.scheme)))
      -1
      url.port)
    (string.copy url.path)
    (url-part-copy (& url.query))
    (url-part-copy (& url.fragment))))

;: Resolve the reference TEXT against BASE and apply the HTTP policy, which
;: rejects a result with another scheme or without an authority.
(define (http-url-resolve
  [base : (& base HttpUrl)]
  [text : (& text str)]
  [limits : UrlLimits]) : HttpUrlResult
  (match (parse-uri-reference text limits)
    [(UriReferenceErr error) (HttpUrlErr error)]
    [(UriReferenceOk reference)
      (let
        [base-reference : UriReference (http-url-to-reference base)]
        (match (uri-reference-resolve (& base-reference) (& reference))
          [(UriReferenceErr error) (HttpUrlErr error)]
          [(UriReferenceOk resolved) (http-url-from-reference (& resolved))]))]))

;: The canonical spelling: lowercase scheme and host, no default port, a
;: non-empty path, and the normalized query and fragment.
(define (http-url-to-string [url : (& url HttpUrl)]) : String
  (let
    [reference : UriReference (http-url-to-reference url)]
    (uri-reference-to-string (& reference))))

;: The origin-form request target: the path and, when present, `?` and the
;: query. The fragment never enters a request target.
(define (http-url-request-target [url : (& url HttpUrl)]) : String
  (url-append-part (string.copy url.path) "?" (& url.query)))

;: The URL's origin: its scheme, host and effective port.
(define (http-url-origin [url : (& url HttpUrl)]) : HttpOrigin
  (HttpOrigin
    (http-scheme-copy (& url.scheme))
    (url-host-copy (& url.host))
    url.port))

;: A byte-stable origin key, `scheme://host:port` with the effective port.
(define (http-origin-key [origin : (& origin HttpOrigin)]) : String
  (str_cat.str-cat
    (http-scheme-name (& origin.scheme))
    "://"
    (url-host-to-string (& origin.host))
    ":"
    (string.int->string origin.port)))

;: Whether two origins have the same key: equal scheme, host and effective
;: port.
(define (http-origin-eq?
  [left : (& left HttpOrigin)]
  [right : (& right HttpOrigin)]) : bool
  (string.eq (http-origin-key left) (http-origin-key right)))

;: A byte-stable key for redirect-loop detection: scheme, host, effective
;: port, path and query. Fragments are excluded because they never reach the
;: server.
(define (http-url-identity-key [url : (& url HttpUrl)]) : String
  (let
    [origin : HttpOrigin (http-url-origin url)]
    (str_cat.str-cat (http-origin-key (& origin)) (http-url-request-target url))))

;: A byte-stable key for the complete URL, including the fragment.
(define (http-url-key [url : (& url HttpUrl)]) : String
  (url-append-part (http-url-identity-key url) "#" (& url.fragment)))