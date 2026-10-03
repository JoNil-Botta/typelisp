(import stdlib.byte_buf)
(import stdlib.ssh_known_hosts_parse as known_hosts)
(import stdlib.str_cat)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (error-code [kind : known_hosts.KnownHostsErrorKind]) : i64
  (match kind
    [(KnownHostsInvalidLimits) 0]
    [(KnownHostsInvalidIdentity) 1]
    [(KnownHostsInvalidSourceId) 2]
    [(KnownHostsPolicyTooLarge) 3]
    [(KnownHostsLineTooLong) 4]
    [(KnownHostsTooManyLines) 5]
    [(KnownHostsTooManyRecords) 6]
    [(KnownHostsBareCarriageReturn) 7]
    [(KnownHostsMalformedMarker) 8]
    [(KnownHostsUnsupportedMarker) 9]
    [(KnownHostsMarkerTooLong) 10]
    [(KnownHostsRepeatedMarker) 11]
    [(KnownHostsMissingSelector) 12]
    [(KnownHostsSelectorTooLong) 13]
    [(KnownHostsMalformedPlainSelector) 14]
    [(KnownHostsTooManyPatterns) 15]
    [(KnownHostsPatternTooLong) 16]
    [(KnownHostsPatternWorkExceeded) 17]
    [(KnownHostsMalformedHashedSelector) 18]
    [(KnownHostsHashFieldTooLong) 19]
    [(KnownHostsMissingKeyFormat) 20]
    [(KnownHostsKeyFormatTooLong) 21]
    [(KnownHostsInvalidKeyFormat) 22]
    [(KnownHostsMissingKeyBase64) 23]
    [(KnownHostsKeyBase64TooLong) 24]
    [(KnownHostsInvalidKeyBase64) 25]
    [(KnownHostsInternalMismatch) 26]))

(define (name-identity [host : String] [port : i64]) : known_hosts.KnownHostsIdentity
  (known_hosts.KnownHostsIdentity host (KnownHostsHostName) port))

(define (ipv6-identity [host : String] [port : i64]) : known_hosts.KnownHostsIdentity
  (known_hosts.KnownHostsIdentity host (KnownHostsHostIpv6) port))

(define (scan-text
  [policy : String]
  [identity : known_hosts.KnownHostsIdentity]
  [limits : known_hosts.KnownHostsLimits]) : known_hosts.KnownHostsScanResult
  (let
    [input : (& policy bytes) (byte_buf.str-as-bytes (& policy))]
    (known_hosts.scan input "user-known-hosts" identity limits)))

(define (selector-matches?
  [selector : String]
  [identity : known_hosts.KnownHostsIdentity]
  [limits : known_hosts.KnownHostsLimits]) : bool
  (let
    [policy : String
      (str_cat.str-cat selector " ssh-ed25519 " "QUJD trailing bytes")]
    (match (scan-text policy identity limits)
      [(KnownHostsScanErr _) false]
      [(KnownHostsScanOk records)
        (and
          (= (known_hosts.records-len (& records)) 1)
          (known_hosts.record-selector-matching?
            (known_hosts.records-ref (& records) 0)))])))

(define (assert-lookup
  [identity : known_hosts.KnownHostsIdentity]
  [expected : String]) : unit
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (match (known_hosts.lookup-token (& identity) (& limits))
      [(KnownHostsLookupErr _) (fail "lookup identity rejected")]
      [(KnownHostsLookupOk actual)
        (test.assert-string-eq (& actual) (& expected) "lookup token")])))

(define (assert-identity-and-lookup) : unit
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (assert-lookup (name-identity "example.test" 22) "example.test")
    (assert-lookup (name-identity "example.test" 2222) "[example.test]:2222")
    (assert-lookup (ipv6-identity "2001:db8::1" 22) "2001:db8::1")
    (assert-lookup (ipv6-identity "2001:db8::1" 2200) "[2001:db8::1]:2200")
    (match (known_hosts.identity-new
      "example.test"
      (KnownHostsHostName)
      22
      limits)
      [(KnownHostsIdentityErr _) (fail "valid identity rejected")]
      [(KnownHostsIdentityOk _) unit])
    (match (known_hosts.identity-new
      "Example.test"
      (KnownHostsHostName)
      22
      limits)
      [(KnownHostsIdentityOk _) (fail "uppercase identity accepted")]
      [(KnownHostsIdentityErr error)
        (test.assert-i64-eq
          (error-code error.kind)
          1
          "uppercase identity error")])
    (match (known_hosts.identity-new
      "2001:db8::1"
      (KnownHostsHostName)
      22
      limits)
      [(KnownHostsIdentityOk _) (fail "inconsistent host kind accepted")]
      [(KnownHostsIdentityErr _) unit])
    (match (known_hosts.identity-new
      "example.test"
      (KnownHostsHostName)
      0
      limits)
      [(KnownHostsIdentityOk _) (fail "zero port accepted")]
      [(KnownHostsIdentityErr _) unit])))

(define (assert-plain-patterns) : unit
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (test.assert-true
      (selector-matches?
        "example.test"
        (name-identity "example.test" 22)
        limits)
      "exact host")
    (test.assert-true
      (selector-matches?
        "EXAMPLE.TEST"
        (name-identity "example.test" 22)
        limits)
      "ASCII case folding")
    (test.assert-true
      (selector-matches? "*.test" (name-identity "example.test" 22) limits)
      "star wildcard")
    (test.assert-true
      (selector-matches? "e?ample.*" (name-identity "example.test" 22) limits)
      "question wildcard")
    (test.assert-false
      (selector-matches?
        "*.example.test"
        (name-identity "example.test" 22)
        limits)
      "wildcard boundary")
    (test.assert-true
      (selector-matches?
        "elsewhere,*.test"
        (name-identity "example.test" 22)
        limits)
      "positive comma list")
    (test.assert-false
      (selector-matches?
        "*.test,!example.test"
        (name-identity "example.test" 22)
        limits)
      "matching negation wins")
    (test.assert-true
      (selector-matches?
        "*.test,!bad.test"
        (name-identity "example.test" 22)
        limits)
      "nonmatching negation")
    (test.assert-false
      (selector-matches? "!bad.test" (name-identity "example.test" 22) limits)
      "negative-only list has no positive match")
    (test.assert-true
      (selector-matches?
        "[example.test]:2222"
        (name-identity "example.test" 2222)
        limits)
      "nondefault name port")
    (test.assert-true
      (selector-matches? "2001:DB8::1" (ipv6-identity "2001:db8::1" 22) limits)
      "raw default IPv6")
    (test.assert-true
      (selector-matches?
        "[2001:db8::*]:2200"
        (ipv6-identity "2001:db8::1" 2200)
        limits)
      "bracketed nondefault IPv6")
    (test.assert-true
      (selector-matches?
        "****************example.test"
        (name-identity "example.test" 22)
        limits)
      "many stars remain bounded")))

(define (assert-record-corpus) : unit
  (let
    [policy : String
      "\n  # ignored comment\r\nEXAMPLE.TEST ssh-ed25519 QUJD first\r\n@revoked *.test ssh-rsa REVG\n@cert-authority other.test ssh-ed25519 R0hJ\n|1|c2FsdA==|ZGlnZXN0 ssh-ed25519 S0VZ\n|2|opaque|digest ssh-ed25519 S0VZ trailing\nnomatch ssh-ed25519 %%% malformed but unrelated\n"]
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr _) (fail "record corpus rejected")]
      [(KnownHostsScanOk records)
        (test.assert-i64-eq
          (known_hosts.records-len (& records))
          6
          "semantic record count")
        (let
          [ordinary : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 0)]
          (test.assert-i64-eq ordinary.semantic-id 1 "semantic id")
          (test.assert-i64-eq ordinary.line 3 "CRLF source line")
          (test.assert-string-eq
            (& ordinary.source-id)
            "user-known-hosts"
            "redacted source id")
          (test.assert-true
            (known_hosts.record-selector-matching? ordinary)
            "ordinary selector match")
          (test.assert-true
            (known_hosts.record-key-valid? ordinary)
            "ordinary key fields")
          (match ordinary.key
            [(KnownHostsKeyFields format base64)
              (test.assert-string-eq (& format) "ssh-ed25519" "key format")
              (test.assert-string-eq (& base64) "QUJD" "key base64")]
            [_ (fail "ordinary key status")]))
        (let
          [revoked : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 1)]
          (match revoked.marker
            [(KnownHostsRevokedMarker) unit]
            [_ (fail "revoked marker")]))
        (let
          [authority : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 2)]
          (match authority.marker
            [(KnownHostsCertAuthorityMarker) unit]
            [_ (fail "cert-authority marker")])
          (test.assert-true
            (known_hosts.record-selector-nonmatching? authority)
            "unrelated CA selector"))
        (let
          [hashed : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 3)]
          (match hashed.selector
            [(KnownHostsHashedPending value)
              (test.assert-string-eq (& value.version) "1" "hash version")
              (test.assert-string-eq
                (& value.salt-base64)
                "c2FsdA=="
                "hash salt")
              (test.assert-string-eq
                (& value.digest-base64)
                "ZGlnZXN0"
                "hash digest")]
            [_ (fail "v1 hash status")]))
        (let
          [unknown-hash : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 4)]
          (match unknown-hash.selector
            [(KnownHostsHashedPending value)
              (test.assert-string-eq
                (& value.version)
                "2"
                "unknown hash version retained")]
            [_ (fail "unknown hash status")]))
        (let
          [unrelated : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 5)]
          (test.assert-true
            (known_hosts.record-selector-nonmatching? unrelated)
            "malformed unrelated key selector")
          (test.assert-false
            (known_hosts.record-key-valid? unrelated)
            "malformed unrelated key retained as status"))])))

(define (assert-selector-error [selector : String] [expected : i64]) : unit
  (let
    [policy : String (str_cat.str-cat selector " ssh-ed25519 " "QUJD")]
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr _) (fail "selector error escaped record")]
      [(KnownHostsScanOk records)
        (match (known_hosts.records-ref (& records) 0).selector
          [(KnownHostsSelectorIndeterminate kind)
            (test.assert-i64-eq
              (error-code (clone kind))
              expected
              "selector error")]
          [_ (fail "malformed selector accepted")])])))

(define (assert-malformed-records) : unit
  (assert-selector-error "foo," 14)
  (assert-selector-error ",foo" 14)
  (assert-selector-error "!" 14)
  (assert-selector-error "!!foo" 14)
  (assert-selector-error "|1||digest" 18)
  (assert-selector-error "|1|salt|" 18)
  (assert-selector-error "|1|salt|digest|extra" 18)
  (assert-selector-error "|1|salt|digest,plain" 18)
  (assert-selector-error "plain,|1|salt|digest" 18)
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    [policy : String "@REVOKED example.test ssh-ed25519 QUJD"]
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr _) (fail "unknown marker escaped record")]
      [(KnownHostsScanOk records)
        (let
          [record : (& records known_hosts.KnownHostsRecord)
            (known_hosts.records-ref (& records) 0)]
          (test.assert-true
            (known_hosts.record-indeterminate? record)
            "unknown marker is indeterminate")
          (match record.marker
            [(KnownHostsMarkerIndeterminate kind)
              (test.assert-i64-eq
                (error-code (clone kind))
                9
                "unsupported marker kind")]
            [_ (fail "unknown marker status")]))]))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    [policy : String "@revoked @cert-authority example.test ssh-ed25519 QUJD"]
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr _) (fail "repeated marker escaped record")]
      [(KnownHostsScanOk records)
        (match (known_hosts.records-ref (& records) 0).selector
          [(KnownHostsSelectorIndeterminate kind)
            (test.assert-i64-eq
              (error-code (clone kind))
              11
              "repeated marker kind")]
          [_ (fail "repeated marker accepted")])])))

(define (assert-scan-error
  [policy : String]
  [limits : known_hosts.KnownHostsLimits]
  [expected : i64]) : unit
  (match (scan-text policy (name-identity "example.test" 22) limits)
    [(KnownHostsScanOk _) (fail "policy-wide error accepted")]
    [(KnownHostsScanErr error)
      (test.assert-i64-eq (error-code error.kind) expected "scan error")]))

(define (set-small-line-limits!
  [limits : (&mut limits known_hosts.KnownHostsLimits)]
  [size : i64]) : unit
  (set! limits.max-line-bytes size)
  (set! limits.max-marker-bytes size)
  (set! limits.max-selector-bytes size)
  (set! limits.max-pattern-bytes size)
  (set! limits.max-key-format-bytes size)
  (set! limits.max-key-base64-bytes size)
  (set! limits.max-hash-version-bytes size)
  (set! limits.max-hash-salt-bytes size)
  (set! limits.max-hash-digest-bytes size))

(define (assert-budgets-and-newlines) : unit
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (set! limits.max-total-bytes 8)
    (set-small-line-limits! (&mut limits) 8)
    (assert-scan-error "example.test ssh-ed25519 QUJD" limits 3))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (set-small-line-limits! (&mut limits) 4)
    (assert-scan-error "abcde" limits 4))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (set! limits.max-lines 1)
    (set! limits.max-records 1)
    (assert-scan-error "# one\n# two\n" limits 5))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (set! limits.max-records 1)
    (assert-scan-error "one ssh-ed25519 QUJD\ntwo ssh-ed25519 QUJD\n" limits 6))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (assert-scan-error "example.test ssh-ed25519 QUJD\rbroken" limits 7))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    [policy : String "example.test ssh-ed25519 QUJD\r\n"]
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr _) (fail "CRLF rejected")]
      [(KnownHostsScanOk records)
        (test.assert-i64-eq
          (known_hosts.records-len (& records))
          1
          "CRLF record count")]))
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    [policy : String "* ssh-ed25519 QUJD"]
    (set! limits.max-pattern-work 5)
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr _) (fail "DP work escaped record")]
      [(KnownHostsScanOk records)
        (match (known_hosts.records-ref (& records) 0).selector
          [(KnownHostsSelectorIndeterminate kind)
            (test.assert-i64-eq (error-code (clone kind)) 17 "DP work bound")]
          [_ (fail "DP work limit ignored")])])
    (let
      [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
      [policy : String "a,b,c ssh-ed25519 QUJD"]
      (set! limits.max-pattern-components 2)
      (match (scan-text policy (name-identity "example.test" 22) limits)
        [(KnownHostsScanErr _) (fail "component limit escaped record")]
        [(KnownHostsScanOk records)
          (match (known_hosts.records-ref (& records) 0).selector
            [(KnownHostsSelectorIndeterminate kind)
              (test.assert-i64-eq
                (error-code (clone kind))
                15
                "component bound")]
            [_ (fail "component limit ignored")])]))))

(define (policy-with-comment-byte [byte : u8]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.from-string "#")]
    (set! buf (byte_buf.push buf byte))
    (set! buf (byte_buf.append-string buf "\nexample.test ssh-ed25519 QUJD\n"))
    (byte_buf.to-string buf)))

(define (policy-with-selector-byte [byte : u8]) : String
  (let
    [buf : byte_buf.ByteBuf (byte_buf.new)]
    (set! buf (byte_buf.push buf byte))
    (set! buf (byte_buf.append-string buf " ssh-ed25519 QUJD\n"))
    (byte_buf.to-string buf)))

(define (scan-summary [policy : String]) : i64
  (let
    [limits : known_hosts.KnownHostsLimits (known_hosts.default-limits)]
    (match (scan-text policy (name-identity "example.test" 22) limits)
      [(KnownHostsScanErr error) (- -100 (error-code error.kind))]
      [(KnownHostsScanOk records)
        (let
          [count : i64 (known_hosts.records-len (& records))]
          (if (= count 0)
            0
            (+
              count
              (if (known_hosts.record-selector-matching?
                (known_hosts.records-ref (& records) 0))
                1000
                0))))])))

(define (assert-arbitrary-byte-determinism) : unit
  (let
    [value : i64 0]
    (while (< value 256)
      (let
        [left : String (policy-with-comment-byte (cast value : u8))]
        [right : String (policy-with-comment-byte (cast value : u8))]
        [structural-left : String (policy-with-selector-byte (cast value : u8))]
        [structural-right : String
          (policy-with-selector-byte (cast value : u8))]
        (test.assert-i64-eq
          (scan-summary left)
          (scan-summary right)
          "arbitrary-byte parse determinism")
        (test.assert-i64-eq
          (scan-summary structural-left)
          (scan-summary structural-right)
          "arbitrary structural-byte determinism")
        (set! value (+ value 1))))))

(define (main) : i64
  (assert-identity-and-lookup)
  (assert-plain-patterns)
  (assert-record-corpus)
  (assert-malformed-records)
  (assert-budgets-and-newlines)
  (assert-arbitrary-byte-determinism)
  42)