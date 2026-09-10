;# Bounded OpenSSH known_hosts structural parsing and plain-host matching.
;#
;# This module accepts one immutable policy snapshot plus a caller-approved
;# redacted source identity. It performs no file I/O, key/base64 decoding,
;# cryptography, DNS, trust decision, or policy mutation. Hashed selectors are
;# retained as bounded opaque fields for `ssh_known_hosts_hash.tl`.
;#
;# Usage: `(import stdlib.ssh_known_hosts_parse)`.
(import stdlib.byte_buf)
(import stdlib.string)

;: Host syntax already normalized by a deterministic endpoint parser.
(defenum KnownHostsHostKind
  (KnownHostsHostName)
  (KnownHostsHostIpv6))

;: Canonical host and port identity used for known_hosts lookup.
(defstruct KnownHostsIdentity
  (host String)
  (kind KnownHostsHostKind)
  (port i64))

;: Independent input, retained-field, component, and DP-work budgets.
(defstruct KnownHostsLimits
  (max-total-bytes i64)
  (max-line-bytes i64)
  (max-lines i64)
  (max-records i64)
  (max-source-id-bytes i64)
  (max-host-bytes i64)
  (max-marker-bytes i64)
  (max-selector-bytes i64)
  (max-pattern-components i64)
  (max-pattern-bytes i64)
  (max-pattern-work i64)
  (max-key-format-bytes i64)
  (max-key-base64-bytes i64)
  (max-hash-version-bytes i64)
  (max-hash-salt-bytes i64)
  (max-hash-digest-bytes i64))

;: Stable local, policy-wide, marker, selector, and key failure categories.
(defenum KnownHostsErrorKind
  (KnownHostsInvalidLimits)
  (KnownHostsInvalidIdentity)
  (KnownHostsInvalidSourceId)
  (KnownHostsPolicyTooLarge)
  (KnownHostsLineTooLong)
  (KnownHostsTooManyLines)
  (KnownHostsTooManyRecords)
  (KnownHostsBareCarriageReturn)
  (KnownHostsMalformedMarker)
  (KnownHostsUnsupportedMarker)
  (KnownHostsMarkerTooLong)
  (KnownHostsRepeatedMarker)
  (KnownHostsMissingSelector)
  (KnownHostsSelectorTooLong)
  (KnownHostsMalformedPlainSelector)
  (KnownHostsTooManyPatterns)
  (KnownHostsPatternTooLong)
  (KnownHostsPatternWorkExceeded)
  (KnownHostsMalformedHashedSelector)
  (KnownHostsHashFieldTooLong)
  (KnownHostsMissingKeyFormat)
  (KnownHostsKeyFormatTooLong)
  (KnownHostsInvalidKeyFormat)
  (KnownHostsMissingKeyBase64)
  (KnownHostsKeyBase64TooLong)
  (KnownHostsInvalidKeyBase64)
  (KnownHostsInternalMismatch))

;: Redacted stable failure location. `offset` is absolute in the snapshot.
(defstruct KnownHostsError
  (kind KnownHostsErrorKind)
  (line i64)
  (offset i64))

;: Marker state is kept independently from selector/key state for policy
;: precedence. Invalid marker records can never degrade to ordinary trust.
(defenum KnownHostsMarkerStatus
  (KnownHostsNoMarker)
  (KnownHostsRevokedMarker)
  (KnownHostsCertAuthorityMarker)
  (KnownHostsMarkerIndeterminate KnownHostsErrorKind))

;: Structurally checked but intentionally undecoded hashed selector fields.
(defstruct KnownHostsHashedSelector
  (version String)
  (salt-base64 String)
  (digest-base64 String))

;: Selector relevance after plain matching. Hashed and malformed selectors are
;: deliberately not reported as nonmatches.
(defenum KnownHostsSelectorStatus
  (KnownHostsPlainMatching String)
  (KnownHostsPlainNonmatching String)
  (KnownHostsHashedPending KnownHostsHashedSelector)
  (KnownHostsSelectorIndeterminate KnownHostsErrorKind))

;: Bounded key tokens are structural bytes only. Canonical base64/key parsing
;: remains the parent policy's responsibility.
(defenum KnownHostsKeyStatus
  (KnownHostsKeyFields String String)
  (KnownHostsKeyIndeterminate KnownHostsErrorKind))

;: One nonblank, noncomment semantic record in source order.
(defstruct KnownHostsRecord
  (semantic-id i64)
  (source-id String)
  (line i64)
  (marker KnownHostsMarkerStatus)
  (selector KnownHostsSelectorStatus)
  (key KnownHostsKeyStatus))

;: Ordered checked record collection. Only `[0, len)` is live.
(defstruct KnownHostsRecords
  (slots (__tl_dyn-array KnownHostsRecord))
  (len i64))

;: Whole-snapshot parse result. Policy-wide failures publish no records.
(defenum KnownHostsScanResult
  (KnownHostsScanOk KnownHostsRecords)
  (KnownHostsScanErr KnownHostsError))

;: Checked identity construction result.
(defenum KnownHostsIdentityResult
  (KnownHostsIdentityOk KnownHostsIdentity)
  (KnownHostsIdentityErr KnownHostsError))

;: Checked canonical lookup-token rendering result.
(defenum KnownHostsLookupResult
  (KnownHostsLookupOk String)
  (KnownHostsLookupErr KnownHostsError))

;: Internal whole-input preflight result.
(defstruct KnownHostsPreflight
  (lines i64)
  (records i64))

(defenum KnownHostsPreflightResult
  (KnownHostsPreflightOk KnownHostsPreflight)
  (KnownHostsPreflightErr KnownHostsError))

;: Internal marker scan result. `cursor` points at the selector token.
(defstruct KnownHostsMarkerParse
  (status KnownHostsMarkerStatus)
  (cursor i64))

;: Internal selector scan result. `cursor` points just after the selector.
(defstruct KnownHostsSelectorParse
  (status KnownHostsSelectorStatus)
  (cursor i64))

;: Conservative defaults for one immutable policy source.
(define (default-limits) : KnownHostsLimits
  (KnownHostsLimits
    1048576
    16384
    16384
    8192
    256
    1024
    32
    8192
    256
    4096
    8388608
    256
    16384
    32
    1024
    1024))

;: True when all limits are positive and their containment rules are coherent.
(define (limits-valid? [limits : (& limits KnownHostsLimits)]) : bool
  (and
    (> limits.max-total-bytes 0)
    (> limits.max-line-bytes 0)
    (> limits.max-lines 0)
    (> limits.max-records 0)
    (> limits.max-source-id-bytes 0)
    (> limits.max-host-bytes 0)
    (> limits.max-marker-bytes 0)
    (> limits.max-selector-bytes 0)
    (> limits.max-pattern-components 0)
    (> limits.max-pattern-bytes 0)
    (> limits.max-pattern-work 0)
    (> limits.max-key-format-bytes 0)
    (> limits.max-key-base64-bytes 0)
    (> limits.max-hash-version-bytes 0)
    (> limits.max-hash-salt-bytes 0)
    (> limits.max-hash-digest-bytes 0)
    (<= limits.max-line-bytes limits.max-total-bytes)
    (<= limits.max-records limits.max-lines)
    (<= limits.max-marker-bytes limits.max-line-bytes)
    (<= limits.max-selector-bytes limits.max-line-bytes)
    (<= limits.max-pattern-bytes limits.max-selector-bytes)
    (<= limits.max-key-format-bytes limits.max-line-bytes)
    (<= limits.max-key-base64-bytes limits.max-line-bytes)
    (<= limits.max-hash-version-bytes limits.max-selector-bytes)
    (<= limits.max-hash-salt-bytes limits.max-selector-bytes)
    (<= limits.max-hash-digest-bytes limits.max-selector-bytes)))

;: Construct a redacted error at a stable source position.
(define (known-hosts-error
  [kind : KnownHostsErrorKind]
  [line : i64]
  [offset : i64]) : KnownHostsError
  (KnownHostsError kind line offset))

;: Return true for ASCII space or horizontal tab.
(define (space-tab? [byte : u8]) : bool
  (let
    [code : i64 (cast byte : i64)]
    (or (= code 32) (= code 9))))

;: Fold one ASCII uppercase byte to lowercase.
(define (ascii-lower [byte : u8]) : u8
  (let
    [code : i64 (cast byte : i64)]
    (if (and (>= code 65) (<= code 90))
      (cast (+ code 32) : u8)
      byte)))

;: True for one visible seven-bit structural byte.
(define (visible-ascii? [byte : u8]) : bool
  (let
    [code : i64 (cast byte : i64)]
    (and (>= code 33) (<= code 126))))

;: Copy `[start,end)` from an immutable policy view into owned text.
(define (copy-byte-range [input : (& source bytes)] [start : i64] [end : i64]) : String
  (let
    [view : (& source bytes)
      (byte_buf.bytes-slice-view input start (- end start))]
    (byte_buf.bytes-to-string view)))

;: Compare a policy range with an exact case-sensitive ASCII spelling.
(define (byte-range-eq-string?
  [input : (& input bytes)]
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
            (byte_buf.bytes-ref input (+ start index))
            (byte_buf.bytes-ref expected index))
            (set! same false)
            unit)
          (set! index (+ index 1))))
      same)))

;: Skip ASCII field separators within one already-bounded line.
(define (skip-space-tab [input : (& input bytes)] [cursor : i64] [end : i64]) : i64
  (let
    [index : i64 cursor]
    (begin
      (while (and (< index end) (space-tab? (byte_buf.bytes-ref input index)))
        (set! index (+ index 1)))
      index)))

;: Return the end of one whitespace-delimited structural token.
(define (token-end [input : (& input bytes)] [cursor : i64] [end : i64]) : i64
  (let
    [index : i64 cursor]
    (begin
      (while (and
        (< index end)
        (not (space-tab? (byte_buf.bytes-ref input index))))
        (set! index (+ index 1)))
      index)))

;: Validate one caller-supplied redacted diagnostic source identity.
(define (source-id-valid?
  [source-id : (& source-id str)]
  [limits : (& limits KnownHostsLimits)]) : bool
  (let
    [view : (& source-id bytes) (byte_buf.str-as-bytes source-id)]
    [count : i64 (byte_buf.bytes-length view)]
    [index : i64 0]
    [valid : bool (and (> count 0) (<= count limits.max-source-id-bytes))]
    (begin
      (while (and valid (< index count))
        (begin
          (if (visible-ascii? (byte_buf.bytes-ref view index))
            unit
            (set! valid false))
          (set! index (+ index 1))))
      valid)))

;: True for ASCII alphanumeric host-name bytes.
(define (host-alnum? [code : i64]) : bool
  (or
    (and (>= code 48) (<= code 57))
    (and (>= code 65) (<= code 90))
    (and (>= code 97) (<= code 122))))

;: Validate the same normalized host-name grammar produced by #7228.
(define (host-name-valid? [host : (& host str)]) : bool
  (let
    [view : (& host bytes) (byte_buf.str-as-bytes host)]
    [length : i64 (byte_buf.bytes-length view)]
    [index : i64 0]
    [previous : i64 -1]
    [valid : bool (> length 0)]
    (begin
      (while (and valid (< index length))
        (let
          [code : i64 (cast (byte_buf.bytes-ref view index) : i64)]
          (begin
            (cond
              [(host-alnum? code) unit]
              [(= code 95) unit]
              [(= code 45)
                (if (or (= index 0) (= previous 46))
                  (set! valid false)
                  unit)]
              [(= code 46)
                (if (or (= index 0) (= previous 46) (= previous 45))
                  (set! valid false)
                  unit)]
              [else (set! valid false)])
            (set! previous code)
            (set! index (+ index 1)))))
      (and valid (!= previous 46) (!= previous 45)))))

;: Return a hexadecimal digit value, or -1.
(define (ascii-hex-value [code : i64]) : i64
  (cond
    [(and (>= code 48) (<= code 57)) (- code 48)]
    [(and (>= code 65) (<= code 70)) (+ 10 (- code 65))]
    [(and (>= code 97) (<= code 102)) (+ 10 (- code 97))]
    [else -1]))

;: Validate the pure-hexadecimal IPv6 grammar produced by #7228.
(define (host-ipv6-valid? [host : (& host str)]) : bool
  (let
    [view : (& host bytes) (byte_buf.str-as-bytes host)]
    [length : i64 (byte_buf.bytes-length view)]
    [index : i64 0]
    [groups : i64 0]
    [compressed : bool false]
    [valid : bool (> length 0)]
    (begin
      (if (and valid (= (cast (byte_buf.bytes-ref view 0) : i64) 58))
        (if (and (> length 1) (= (cast (byte_buf.bytes-ref view 1) : i64) 58))
          (begin
            (set! compressed true)
            (set! index 2))
          (set! valid false))
        unit)
      (while (and valid (< index length))
        (let
          [group-start : i64 index]
          [digits : i64 0]
          (begin
            (while (and
              (< index length)
              (!= (cast (byte_buf.bytes-ref view index) : i64) 58)
              (< digits 5))
              (begin
                (if (<
                  (ascii-hex-value (cast (byte_buf.bytes-ref view index) : i64))
                  0)
                  (set! valid false)
                  unit)
                (set! digits (+ digits 1))
                (set! index (+ index 1))))
            (if (or (not valid) (= digits 0) (> digits 4) (= group-start index))
              (set! valid false)
              (set! groups (+ groups 1)))
            (if (and valid (< index length))
              (if (and
                (< (+ index 1) length)
                (= (cast (byte_buf.bytes-ref view (+ index 1)) : i64) 58))
                (if compressed
                  (set! valid false)
                  (begin
                    (set! compressed true)
                    (set! index (+ index 2))))
                (begin
                  (set! index (+ index 1))
                  (if (= index length)
                    (set! valid false)
                    unit)))
              unit))))
      (and
        valid
        (if compressed
          (< groups 8)
          (= groups 8))))))

;: Verify lowercase ASCII and the selected host syntax without normalization.
(define (identity-valid?
  [identity : (& identity KnownHostsIdentity)]
  [limits : (& limits KnownHostsLimits)]) : bool
  (let
    [host : (& identity str) (& identity.host)]
    [view : (& identity bytes) (byte_buf.str-as-bytes host)]
    [length : i64 (byte_buf.bytes-length view)]
    [index : i64 0]
    [normalized : bool (and (> length 0) (<= length limits.max-host-bytes))]
    (begin
      (while (and normalized (< index length))
        (let
          [byte : u8 (byte_buf.bytes-ref view index)]
          (begin
            (if (= byte (ascii-lower byte))
              unit
              (set! normalized false))
            (set! index (+ index 1)))))
      (and
        normalized
        (>= identity.port 1)
        (<= identity.port 65535)
        (match identity.kind
          [(KnownHostsHostName) (host-name-valid? host)]
          [(KnownHostsHostIpv6) (host-ipv6-valid? host)]
          [_ false])))))

;: Construct one identity only after exact host/kind/port validation.
(define (identity-new
  [host : String]
  [kind : KnownHostsHostKind]
  [port : i64]
  [limits : KnownHostsLimits]) : KnownHostsIdentityResult
  (let
    [identity : KnownHostsIdentity (KnownHostsIdentity host kind port)]
    (cond
      [(not (limits-valid? (& limits)))
        (KnownHostsIdentityErr
          (known-hosts-error (KnownHostsInvalidLimits) 0 0))]
      [(not (identity-valid? (& identity) (& limits)))
        (KnownHostsIdentityErr
          (known-hosts-error (KnownHostsInvalidIdentity) 0 0))]
      [else (KnownHostsIdentityOk identity)])))

;: Render host alone for port 22 and `[host]:port` otherwise.
(define (lookup-token
  [identity : (& identity KnownHostsIdentity)]
  [limits : (& limits KnownHostsLimits)]) : KnownHostsLookupResult
  (if (not (identity-valid? identity limits))
    (KnownHostsLookupErr (known-hosts-error (KnownHostsInvalidIdentity) 0 0))
    (if (= identity.port 22)
      (KnownHostsLookupOk (string.copy (& identity.host)))
      (let
        [port-text : String (string.int->string identity.port)]
        [token : String
          (string.concat5 "[" (string.copy (& identity.host)) "]" ":" port-text)]
        (KnownHostsLookupOk token)))))

;: Number of checked records.
(define (records-len [records : (& records KnownHostsRecords)]) : i64
  records.len)

;: Borrow checked record `index`; callers establish `0 <= index < len`.
(define (records-ref [records : (& source KnownHostsRecords)] [index : i64]) : (&
    source
    KnownHostsRecord)
  (& (array-ref records.slots index)))

;: True only for a valid plain selector that definitely matched.
(define (record-selector-matching? [record : (& record KnownHostsRecord)]) : bool
  (match record.selector
    [(KnownHostsPlainMatching _) true]
    [_ false]))

;: True only for a valid plain selector that definitely did not match.
(define (record-selector-nonmatching? [record : (& record KnownHostsRecord)]) : bool
  (match record.selector
    [(KnownHostsPlainNonmatching _) true]
    [_ false]))

;: True only for a structurally valid opaque hashed selector.
(define (record-selector-hashed-pending? [record : (& record KnownHostsRecord)]) : bool
  (match record.selector
    [(KnownHostsHashedPending _) true]
    [_ false]))

;: True when marker or selector relevance cannot be safely ignored.
(define (record-indeterminate? [record : (& record KnownHostsRecord)]) : bool
  (or
    (match record.marker
      [(KnownHostsMarkerIndeterminate _) true]
      [_ false])
    (match record.selector
      [(KnownHostsSelectorIndeterminate _) true]
      [_ false])))

;: True only when both bounded key tokens were structurally accepted.
(define (record-key-valid? [record : (& record KnownHostsRecord)]) : bool
  (match record.key
    [(KnownHostsKeyFields _ _) true]
    [_ false]))

;: True when a line is a nonblank, noncomment semantic record.
(define (line-is-record? [input : (& input bytes)] [start : i64] [end : i64]) : bool
  (let
    [cursor : i64 (skip-space-tab input start end)]
    (and (< cursor end) (!= (cast (byte_buf.bytes-ref input cursor) : i64) 35))))

;: Preflight every global size/newline/count rule before retained allocation.
(define (policy-preflight
  [input : (& input bytes)]
  [limits : (& limits KnownHostsLimits)]) : KnownHostsPreflightResult
  (let
    [length : i64 (byte_buf.bytes-length input)]
    (if (> length limits.max-total-bytes)
      (KnownHostsPreflightErr
        (known-hosts-error (KnownHostsPolicyTooLarge) 0 length))
      (let
        [cursor : i64 0]
        [line-start : i64 0]
        [line-number : i64 1]
        [line-count : i64 0]
        [record-count : i64 0]
        [failed : bool false]
        [failure : KnownHostsError
          (known-hosts-error (KnownHostsInternalMismatch) 0 0)]
        (begin
          (while (and (not failed) (< cursor length))
            (let
              [byte : i64 (cast (byte_buf.bytes-ref input cursor) : i64)]
              (cond
                [(= byte 13)
                  (if (or
                    (= (+ cursor 1) length)
                    (!= (cast (byte_buf.bytes-ref input (+ cursor 1)) : i64) 10))
                    (begin
                      (set! failed true)
                      (set!
                        failure
                        (known-hosts-error
                          (KnownHostsBareCarriageReturn)
                          line-number
                          cursor)))
                    (let
                      [line-length : i64 (- cursor line-start)]
                      (if (> line-length limits.max-line-bytes)
                        (begin
                          (set! failed true)
                          (set!
                            failure
                            (known-hosts-error
                              (KnownHostsLineTooLong)
                              line-number
                              line-start)))
                        (begin
                          (set! line-count (+ line-count 1))
                          (if (line-is-record? input line-start cursor)
                            (set! record-count (+ record-count 1))
                            unit)
                          (cond
                            [(> line-count limits.max-lines)
                              (begin
                                (set! failed true)
                                (set!
                                  failure
                                  (known-hosts-error
                                    (KnownHostsTooManyLines)
                                    line-number
                                    line-start)))]
                            [(> record-count limits.max-records)
                              (begin
                                (set! failed true)
                                (set!
                                  failure
                                  (known-hosts-error
                                    (KnownHostsTooManyRecords)
                                    line-number
                                    line-start)))]
                            [else
                              (begin
                                (set! cursor (+ cursor 1))
                                (set! line-start (+ cursor 1))
                                (set! line-number (+ line-number 1)))])
                          unit))))]
                [(= byte 10)
                  (let
                    [line-length : i64 (- cursor line-start)]
                    (if (> line-length limits.max-line-bytes)
                      (begin
                        (set! failed true)
                        (set!
                          failure
                          (known-hosts-error
                            (KnownHostsLineTooLong)
                            line-number
                            line-start)))
                      (begin
                        (set! line-count (+ line-count 1))
                        (if (line-is-record? input line-start cursor)
                          (set! record-count (+ record-count 1))
                          unit)
                        (cond
                          [(> line-count limits.max-lines)
                            (begin
                              (set! failed true)
                              (set!
                                failure
                                (known-hosts-error
                                  (KnownHostsTooManyLines)
                                  line-number
                                  line-start)))]
                          [(> record-count limits.max-records)
                            (begin
                              (set! failed true)
                              (set!
                                failure
                                (known-hosts-error
                                  (KnownHostsTooManyRecords)
                                  line-number
                                  line-start)))]
                          [else
                            (begin
                              (set! line-start (+ cursor 1))
                              (set! line-number (+ line-number 1)))])
                        unit)))]
                [else
                  (if (> (- (+ cursor 1) line-start) limits.max-line-bytes)
                    (begin
                      (set! failed true)
                      (set!
                        failure
                        (known-hosts-error
                          (KnownHostsLineTooLong)
                          line-number
                          line-start)))
                    unit)]))
            (set! cursor (+ cursor 1)))
          (if failed
            (KnownHostsPreflightErr failure)
            (begin
              (if (< line-start length)
                (begin
                  (set! line-count (+ line-count 1))
                  (if (line-is-record? input line-start length)
                    (set! record-count (+ record-count 1))
                    unit))
                unit)
              (cond
                [(> line-count limits.max-lines)
                  (KnownHostsPreflightErr
                    (known-hosts-error
                      (KnownHostsTooManyLines)
                      line-number
                      line-start))]
                [(> record-count limits.max-records)
                  (KnownHostsPreflightErr
                    (known-hosts-error
                      (KnownHostsTooManyRecords)
                      line-number
                      line-start))]
                [else
                  (KnownHostsPreflightOk
                    (KnownHostsPreflight line-count record-count))]))))))))

;: Match one pattern range with two reusable DP rows. Work is exactly
;: `pattern-length * (host-length + 1)` and never backtracks.
(define (pattern-range-matches?
  [pattern : (& pattern bytes)]
  [start : i64]
  [end : i64]
  [host : (& host bytes)]
  [previous : (&mut previous (__tl_dyn-array bool))]
  [current : (&mut current (__tl_dyn-array bool))]) : bool
  (let
    [host-length : i64 (byte_buf.bytes-length host)]
    [cell : i64 0]
    [pattern-index : i64 0]
    (begin
      (while (<= cell host-length)
        (begin
          (set! (array-ref previous cell) false)
          (set! (array-ref current cell) false)
          (set! cell (+ cell 1))))
      (set! (array-ref previous 0) true)
      (while (< (+ start pattern-index) end)
        (let
          [pattern-byte : u8
            (byte_buf.bytes-ref pattern (+ start pattern-index))]
          [use-previous : bool (= (% pattern-index 2) 0)]
          (begin
            (if use-previous
              (begin
                (set!
                  (array-ref current 0)
                  (if (= (cast pattern-byte : i64) 42)
                    (array-ref previous 0)
                    false))
                (set! cell 1)
                (while (<= cell host-length)
                  (begin
                    (set!
                      (array-ref current cell)
                      (cond
                        [(= (cast pattern-byte : i64) 42)
                          (or
                            (array-ref previous cell)
                            (array-ref current (- cell 1)))]
                        [(= (cast pattern-byte : i64) 63)
                          (array-ref previous (- cell 1))]
                        [else
                          (and
                            (array-ref previous (- cell 1))
                            (=
                              (ascii-lower pattern-byte)
                              (ascii-lower (byte_buf.bytes-ref host (- cell 1)))))]))
                    (set! cell (+ cell 1)))))
              (begin
                (set!
                  (array-ref previous 0)
                  (if (= (cast pattern-byte : i64) 42)
                    (array-ref current 0)
                    false))
                (set! cell 1)
                (while (<= cell host-length)
                  (begin
                    (set!
                      (array-ref previous cell)
                      (cond
                        [(= (cast pattern-byte : i64) 42)
                          (or
                            (array-ref current cell)
                            (array-ref previous (- cell 1)))]
                        [(= (cast pattern-byte : i64) 63)
                          (array-ref current (- cell 1))]
                        [else
                          (and
                            (array-ref current (- cell 1))
                            (=
                              (ascii-lower pattern-byte)
                              (ascii-lower (byte_buf.bytes-ref host (- cell 1)))))]))
                    (set! cell (+ cell 1))))))
            (set! pattern-index (+ pattern-index 1)))))
      (if (= (% pattern-index 2) 0)
        (array-ref previous host-length)
        (array-ref current host-length)))))

;: Parse and exhaustively match a comma-separated plain selector list.
(define (parse-plain-selector
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [host : (& host bytes)]
  [limits : (& limits KnownHostsLimits)]
  [previous : (&mut previous (__tl_dyn-array bool))]
  [current : (&mut current (__tl_dyn-array bool))]) : KnownHostsSelectorStatus
  (let
    [cursor : i64 start]
    [component-count : i64 0]
    [work : i64 0]
    [positive-match : bool false]
    [negative-match : bool false]
    [failed : bool
      (and
        (> end start)
        (= (cast (byte_buf.bytes-ref input (- end 1)) : i64) 44))]
    [failure : KnownHostsErrorKind (KnownHostsMalformedPlainSelector)]
    [host-width : i64 (+ (byte_buf.bytes-length host) 1)]
    (begin
      (while (and (not failed) (< cursor end))
        (let
          [component-start : i64 cursor]
          [component-end : i64 cursor]
          [negated : bool false]
          (begin
            (while (and
              (< component-end end)
              (!= (cast (byte_buf.bytes-ref input component-end) : i64) 44))
              (set! component-end (+ component-end 1)))
            (set! component-count (+ component-count 1))
            (cond
              [(> component-count limits.max-pattern-components)
                (begin
                  (set! failed true)
                  (set! failure (KnownHostsTooManyPatterns)))]
              [(= component-start component-end)
                (begin
                  (set! failed true)
                  (set! failure (KnownHostsMalformedPlainSelector)))]
              [else
                (begin
                  (if (=
                    (cast (byte_buf.bytes-ref input component-start) : i64)
                    33)
                    (begin
                      (set! negated true)
                      (set! component-start (+ component-start 1)))
                    unit)
                  (cond
                    [(= component-start component-end)
                      (begin
                        (set! failed true)
                        (set! failure (KnownHostsMalformedPlainSelector)))]
                    [(=
                        (cast (byte_buf.bytes-ref input component-start) : i64)
                        33)
                      (begin
                        (set! failed true)
                        (set! failure (KnownHostsMalformedPlainSelector)))]
                    [(=
                        (cast (byte_buf.bytes-ref input component-start) : i64)
                        124)
                      (begin
                        (set! failed true)
                        (set! failure (KnownHostsMalformedHashedSelector)))]
                    [else
                      (let
                        [pattern-length : i64 (- component-end component-start)]
                        [scan : i64 component-start]
                        [component-valid : bool true]
                        (begin
                          (while (and component-valid (< scan component-end))
                            (begin
                              (if (visible-ascii?
                                (byte_buf.bytes-ref input scan))
                                unit
                                (set! component-valid false))
                              (set! scan (+ scan 1))))
                          (cond
                            [(not component-valid)
                              (begin
                                (set! failed true)
                                (set!
                                  failure
                                  (KnownHostsMalformedPlainSelector)))]
                            [(> pattern-length limits.max-pattern-bytes)
                              (begin
                                (set! failed true)
                                (set! failure (KnownHostsPatternTooLong)))]
                            [(or
                                (>
                                  pattern-length
                                  (/ limits.max-pattern-work host-width))
                                (>
                                  work
                                  (-
                                    limits.max-pattern-work
                                    (* pattern-length host-width))))
                              (begin
                                (set! failed true)
                                (set! failure (KnownHostsPatternWorkExceeded)))]
                            [else
                              (let
                                [matches : bool
                                  (pattern-range-matches?
                                    input
                                    component-start
                                    component-end
                                    host
                                    previous
                                    current)]
                                (begin
                                  (set!
                                    work
                                    (+ work (* pattern-length host-width)))
                                  (if matches
                                    (if negated
                                      (set! negative-match true)
                                      (set! positive-match true))
                                    unit)))])
                          unit))])
                  unit)])
            (set! cursor (+ component-end 1)))))
      (if failed
        (KnownHostsSelectorIndeterminate failure)
        (let
          [selector : String (copy-byte-range input start end)]
          (if (and positive-match (not negative-match))
            (KnownHostsPlainMatching selector)
            (KnownHostsPlainNonmatching selector)))))))

;: Parse exact `|version|salt|digest` syntax without decoding any field.
(define (parse-hashed-selector
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [limits : (& limits KnownHostsLimits)]) : KnownHostsSelectorStatus
  (let
    [cursor : i64 (+ start 1)]
    [first-delimiter : i64 -1]
    [second-delimiter : i64 -1]
    [extra-delimiter : bool false]
    [forbidden : bool false]
    (begin
      (while (< cursor end)
        (let
          [byte : u8 (byte_buf.bytes-ref input cursor)]
          [code : i64 (cast byte : i64)]
          (begin
            (if (not (visible-ascii? byte))
              (set! forbidden true)
              unit)
            (cond
              [(= code 124)
                (cond
                  [(< first-delimiter 0) (set! first-delimiter cursor)]
                  [(< second-delimiter 0) (set! second-delimiter cursor)]
                  [else (set! extra-delimiter true)])]
              [(or (= code 44) (= code 33) (= code 42) (= code 63))
                (set! forbidden true)]
              [else unit])
            (set! cursor (+ cursor 1)))))
      (if (or
        forbidden
        extra-delimiter
        (< first-delimiter 0)
        (< second-delimiter 0)
        (= first-delimiter (+ start 1))
        (= second-delimiter (+ first-delimiter 1))
        (= second-delimiter (- end 1)))
        (KnownHostsSelectorIndeterminate (KnownHostsMalformedHashedSelector))
        (let
          [version-length : i64 (- first-delimiter (+ start 1))]
          [salt-length : i64 (- second-delimiter (+ first-delimiter 1))]
          [digest-length : i64 (- end (+ second-delimiter 1))]
          (if (or
            (> version-length limits.max-hash-version-bytes)
            (> salt-length limits.max-hash-salt-bytes)
            (> digest-length limits.max-hash-digest-bytes))
            (KnownHostsSelectorIndeterminate (KnownHostsHashFieldTooLong))
            (KnownHostsHashedPending
              (KnownHostsHashedSelector
                (copy-byte-range input (+ start 1) first-delimiter)
                (copy-byte-range input (+ first-delimiter 1) second-delimiter)
                (copy-byte-range input (+ second-delimiter 1) end)))))))))

;: Parse the optional exact marker and leave the cursor at the selector.
(define (parse-marker
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [limits : (& limits KnownHostsLimits)]) : KnownHostsMarkerParse
  (let
    [cursor : i64 (skip-space-tab input start end)]
    (if (or
      (= cursor end)
      (!= (cast (byte_buf.bytes-ref input cursor) : i64) 64))
      (KnownHostsMarkerParse (KnownHostsNoMarker) cursor)
      (let
        [marker-end : i64 (token-end input cursor end)]
        [marker-length : i64 (- marker-end cursor)]
        [next : i64 (skip-space-tab input marker-end end)]
        (cond
          [(> marker-length limits.max-marker-bytes)
            (KnownHostsMarkerParse
              (KnownHostsMarkerIndeterminate (KnownHostsMarkerTooLong))
              next)]
          [(= marker-length 1)
            (KnownHostsMarkerParse
              (KnownHostsMarkerIndeterminate (KnownHostsMalformedMarker))
              next)]
          [(byte-range-eq-string? input cursor marker-end "@revoked")
            (KnownHostsMarkerParse (KnownHostsRevokedMarker) next)]
          [(byte-range-eq-string? input cursor marker-end "@cert-authority")
            (KnownHostsMarkerParse (KnownHostsCertAuthorityMarker) next)]
          [else
            (KnownHostsMarkerParse
              (KnownHostsMarkerIndeterminate (KnownHostsUnsupportedMarker))
              next)])))))

;: Parse and match one selector token, preserving indeterminate relevance.
(define (parse-selector
  [input : (& input bytes)]
  [cursor : i64]
  [end : i64]
  [host : (& host bytes)]
  [limits : (& limits KnownHostsLimits)]
  [previous : (&mut previous (__tl_dyn-array bool))]
  [current : (&mut current (__tl_dyn-array bool))]) : KnownHostsSelectorParse
  (if (= cursor end)
    (KnownHostsSelectorParse
      (KnownHostsSelectorIndeterminate (KnownHostsMissingSelector))
      end)
    (let
      [selector-end : i64 (token-end input cursor end)]
      [selector-length : i64 (- selector-end cursor)]
      (cond
        [(> selector-length limits.max-selector-bytes)
          (KnownHostsSelectorParse
            (KnownHostsSelectorIndeterminate (KnownHostsSelectorTooLong))
            selector-end)]
        [(= (cast (byte_buf.bytes-ref input cursor) : i64) 64)
          (KnownHostsSelectorParse
            (KnownHostsSelectorIndeterminate (KnownHostsRepeatedMarker))
            selector-end)]
        [(= (cast (byte_buf.bytes-ref input cursor) : i64) 124)
          (KnownHostsSelectorParse
            (parse-hashed-selector input cursor selector-end limits)
            selector-end)]
        [else
          (KnownHostsSelectorParse
            (parse-plain-selector
              input
              cursor
              selector-end
              host
              limits
              previous
              current)
            selector-end)]))))

;: True for the standard base64 token alphabet. Canonical padding and decoded
;: key structure are deliberately deferred to the parent policy.
(define (base64-byte? [byte : u8]) : bool
  (let
    [code : i64 (cast byte : i64)]
    (or
      (and (>= code 65) (<= code 90))
      (and (>= code 97) (<= code 122))
      (and (>= code 48) (<= code 57))
      (= code 43)
      (= code 47)
      (= code 61))))

;: Parse bounded key-format/base64 tokens and ignore the trailing comment.
(define (parse-key-fields
  [input : (& input bytes)]
  [cursor : i64]
  [end : i64]
  [limits : (& limits KnownHostsLimits)]) : KnownHostsKeyStatus
  (let
    [format-start : i64 (skip-space-tab input cursor end)]
    (if (= format-start end)
      (KnownHostsKeyIndeterminate (KnownHostsMissingKeyFormat))
      (let
        [format-end : i64 (token-end input format-start end)]
        [format-length : i64 (- format-end format-start)]
        [format-scan : i64 format-start]
        [format-valid : bool true]
        (begin
          (while (and format-valid (< format-scan format-end))
            (begin
              (if (visible-ascii? (byte_buf.bytes-ref input format-scan))
                unit
                (set! format-valid false))
              (set! format-scan (+ format-scan 1))))
          (cond
            [(> format-length limits.max-key-format-bytes)
              (KnownHostsKeyIndeterminate (KnownHostsKeyFormatTooLong))]
            [(not format-valid)
              (KnownHostsKeyIndeterminate (KnownHostsInvalidKeyFormat))]
            [else
              (let
                [base64-start : i64 (skip-space-tab input format-end end)]
                (if (= base64-start end)
                  (KnownHostsKeyIndeterminate (KnownHostsMissingKeyBase64))
                  (let
                    [base64-end : i64 (token-end input base64-start end)]
                    [base64-length : i64 (- base64-end base64-start)]
                    [base64-scan : i64 base64-start]
                    [base64-valid : bool true]
                    (begin
                      (while (and base64-valid (< base64-scan base64-end))
                        (begin
                          (if (base64-byte?
                            (byte_buf.bytes-ref input base64-scan))
                            unit
                            (set! base64-valid false))
                          (set! base64-scan (+ base64-scan 1))))
                      (cond
                        [(> base64-length limits.max-key-base64-bytes)
                          (KnownHostsKeyIndeterminate
                            (KnownHostsKeyBase64TooLong))]
                        [(not base64-valid)
                          (KnownHostsKeyIndeterminate
                            (KnownHostsInvalidKeyBase64))]
                        [else
                          (KnownHostsKeyFields
                            (copy-byte-range input format-start format-end)
                            (copy-byte-range input base64-start base64-end))])))))]))))))

;: Parse one already-preflighted semantic line.
(define (parse-record
  [input : (& input bytes)]
  [start : i64]
  [end : i64]
  [source-id : (& source-id str)]
  [line : i64]
  [semantic-id : i64]
  [host : (& host bytes)]
  [limits : (& limits KnownHostsLimits)]
  [previous : (&mut previous (__tl_dyn-array bool))]
  [current : (&mut current (__tl_dyn-array bool))]) : KnownHostsRecord
  (let
    [marker : KnownHostsMarkerParse (parse-marker input start end limits)]
    [selector : KnownHostsSelectorParse
      (parse-selector input marker.cursor end host limits previous current)]
    [key : KnownHostsKeyStatus
      (parse-key-fields input selector.cursor end limits)]
    (KnownHostsRecord
      semantic-id
      (string.copy source-id)
      line
      marker.status
      selector.status
      key)))

;: Parse one immutable known_hosts snapshot after validating all local inputs.
;: Whole-input limits/newlines/counts are preflighted before record/DP storage
;: is allocated, so a policy-wide failure never publishes a partial prefix.
(define (scan
  [input : (& input bytes)]
  [source-id : String]
  [identity : KnownHostsIdentity]
  [limits : KnownHostsLimits]) : KnownHostsScanResult
  (cond
    [(not (limits-valid? (& limits)))
      (KnownHostsScanErr (known-hosts-error (KnownHostsInvalidLimits) 0 0))]
    [(not (source-id-valid? (& source-id) (& limits)))
      (KnownHostsScanErr (known-hosts-error (KnownHostsInvalidSourceId) 0 0))]
    [(not (identity-valid? (& identity) (& limits)))
      (KnownHostsScanErr (known-hosts-error (KnownHostsInvalidIdentity) 0 0))]
    [else
      (match (policy-preflight input (& limits))
        [(KnownHostsPreflightErr error) (KnownHostsScanErr error)]
        [(KnownHostsPreflightOk preflight)
          (match (lookup-token (& identity) (& limits))
            [(KnownHostsLookupErr error) (KnownHostsScanErr error)]
            [(KnownHostsLookupOk token)
              (let
                [host : (& token bytes) (byte_buf.str-as-bytes (& token))]
                [previous : (__tl_dyn-array bool)
                  (__tl_make-array bool (+ (byte_buf.bytes-length host) 1))]
                [current : (__tl_dyn-array bool)
                  (__tl_make-array bool (+ (byte_buf.bytes-length host) 1))]
                [slots : (__tl_dyn-array KnownHostsRecord)
                  (__tl_make-array KnownHostsRecord preflight.records)]
                [length : i64 (byte_buf.bytes-length input)]
                [cursor : i64 0]
                [line-start : i64 0]
                [line-number : i64 1]
                [record-index : i64 0]
                (begin
                  (while (< cursor length)
                    (let
                      [byte : i64
                        (cast (byte_buf.bytes-ref input cursor) : i64)]
                      (cond
                        [(= byte 13)
                          (begin
                            (if (line-is-record? input line-start cursor)
                              (begin
                                (set!
                                  (array-ref slots record-index)
                                  (parse-record
                                    input
                                    line-start
                                    cursor
                                    (& source-id)
                                    line-number
                                    (+ record-index 1)
                                    host
                                    (& limits)
                                    (&mut previous)
                                    (&mut current)))
                                (set! record-index (+ record-index 1)))
                              unit)
                            (set! cursor (+ cursor 1))
                            (set! line-start (+ cursor 1))
                            (set! line-number (+ line-number 1)))]
                        [(= byte 10)
                          (begin
                            (if (line-is-record? input line-start cursor)
                              (begin
                                (set!
                                  (array-ref slots record-index)
                                  (parse-record
                                    input
                                    line-start
                                    cursor
                                    (& source-id)
                                    line-number
                                    (+ record-index 1)
                                    host
                                    (& limits)
                                    (&mut previous)
                                    (&mut current)))
                                (set! record-index (+ record-index 1)))
                              unit)
                            (set! line-start (+ cursor 1))
                            (set! line-number (+ line-number 1)))]
                        [else unit]))
                    (set! cursor (+ cursor 1)))
                  (if (< line-start length)
                    (when
                      (line-is-record? input line-start length)
                      (begin
                        (set!
                          (array-ref slots record-index)
                          (parse-record
                            input
                            line-start
                            length
                            (& source-id)
                            line-number
                            (+ record-index 1)
                            host
                            (& limits)
                            (&mut previous)
                            (&mut current)))
                        (set! record-index (+ record-index 1))))
                    unit)
                  (if (= record-index preflight.records)
                    (KnownHostsScanOk (KnownHostsRecords slots record-index))
                    (KnownHostsScanErr
                      (known-hosts-error
                        (KnownHostsInternalMismatch)
                        line-number
                        line-start)))))])])]))

(test
  known-hosts-plain-basic
  (let
    [limits : KnownHostsLimits (default-limits)]
    [identity : KnownHostsIdentity
      (KnownHostsIdentity "example.test" (KnownHostsHostName) 22)]
    [policy : String
      "# ignored\n*.test,!bad.test ssh-ed25519 QUJD trailing comment\n"]
    [bytes : (& policy bytes) (byte_buf.str-as-bytes (& policy))]
    (match (scan bytes "fixture" identity limits)
      [(KnownHostsScanErr _)
        (begin
          (/ 1 0)
          unit)]
      [(KnownHostsScanOk records)
        (if (and
          (= (records-len (& records)) 1)
          (record-selector-matching? (records-ref (& records) 0))
          (record-key-valid? (records-ref (& records) 0)))
          unit
          (begin
            (/ 1 0)
            unit))])))