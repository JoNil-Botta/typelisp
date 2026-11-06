(import stdlib.asn1_der as der)
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.net.ip)
(import stdlib.pem)
(import stdlib.profile)
(import stdlib.str_cat)
(import stdlib.string)
(import stdlib.test)
(import stdlib.vector)
(import stdlib.x509)
(import stdlib.x509_time as time)
(import (vector.vector x509.Extension core) as extensions)
(import (vector.vector x509.GeneralName core) as names)
(import (vector.vector x509.Constraint core) as constraints)
(import (vector.vector x509.Certificate core) as certificates)
(import (vector.vector x509.Attribute core) as attributes)
(import (vector.vector der.Range core) as ranges)
(import (vector.vector pem.Block core) as blocks)

(include-str rsa-hex "stdlib/tests/fixtures/x509/rsa.hex.in")
(include-str ec-hex "stdlib/tests/fixtures/x509/ec.hex.in")
(include-str ed-hex "stdlib/tests/fixtures/x509/ed.hex.in")
(include-str pss-hex "stdlib/tests/fixtures/x509/pss.hex.in")
(include-str rsa-pem "stdlib/tests/fixtures/x509/rsa.pem.in")

(define (hex-nibble [code : char]) : i64
  (let
    [number : i64 (cast code : i64)]
    (if (<= number 57)
      (- number 48)
      (- number 87))))

(define (hex-bytes [text : (& text str)]) : byte_buf.ByteBuf
  (let
    [position : i64 0]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (/ (string-length text) 2))]
    (while (< position (string-length text))
      (set!
        out
        (byte_buf.push
          out
          (cast
            (+
              (* (hex-nibble (string-ref text position)) 16)
              (hex-nibble (string-ref text (+ position 1))))
            : u8)))
      (set! position (+ position 2)))
    out))

(define (tlv [tag : i64] [content : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (let
    [length : i64 (byte_buf.len content)]
    [out : byte_buf.ByteBuf (byte_buf.new)]
    (set! out (byte_buf.push out (cast tag : u8)))
    (if (< length 128)
      (set! out (byte_buf.push out (cast length : u8)))
      (if (< length 256)
        (begin
          (set! out (byte_buf.push out (cast 129 : u8)))
          (set! out (byte_buf.push out (cast length : u8))))
        (begin
          (set! out (byte_buf.push out (cast 130 : u8)))
          (set! out (byte_buf.push out (cast (/ length 256) : u8)))
          (set! out (byte_buf.push out (cast (% length 256) : u8))))))
    (byte_buf.append-bytes out (byte_buf.as-bytes (& content)))))

(define (hex [text : String]) : byte_buf.ByteBuf
  (hex-bytes (& text)))

(define (append [left : byte_buf.ByteBuf] [right : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (byte_buf.append-bytes left (byte_buf.as-bytes (& right))))

(define (zeros [count : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (set! out (byte_buf.push out (cast 0 : u8)))
      (set! index (+ index 1)))
    out))

; Synthetic signatures/keys deliberately carry no authenticity. These exercise
; encoding only, alongside the independently signed pinned fixtures below.
(define (synthetic-profile
  [extension : byte_buf.ByteBuf]
  [prefix : String]
  [unique : String]) : byte_buf.ByteBuf
  (let
    [algorithm : String "300506032b6570"]
    [name : String "300c310a300806035504030c0141"]
    [start : String "500101000000Z"]
    [end : String "491231235959Z"]
    [tbs : byte_buf.ByteBuf (hex prefix)]
    (set! tbs (append tbs (hex (clone algorithm))))
    (set! tbs (append tbs (hex (clone name))))
    (set!
      tbs
      (append
        tbs
        (tlv
          48
          (append
            (tlv 23 (byte_buf.from-string start))
            (tlv 23 (byte_buf.from-string end))))))
    (set! tbs (append tbs (hex name)))
    (set!
      tbs
      (append tbs (tlv 48 (append (hex (clone algorithm)) (tlv 3 (zeros 33))))))
    (set! tbs (append tbs (hex unique)))
    (when
      (> (byte_buf.len extension) 0)
      (set! tbs (append tbs (tlv 163 (tlv 48 extension)))))
    (tlv 48 (append (append (tlv 48 tbs) (hex algorithm)) (tlv 3 (zeros 65))))))

(define (synthetic [extension : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (synthetic-profile extension "a003020102020101" ""))

(define (extension [suffix : i64] [critical : bool] [value : String]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (hex "0603551d")]
    (set! out (byte_buf.push out (cast suffix : u8)))
    (when critical (set! out (append out (hex "0101ff"))))
    (tlv 48 (append out (tlv 4 (hex value))))))

(define (expect-rejected [bytes : (& bytes bytes)]) : der.Error
  (match (x509.parse-der bytes (x509.default-limits))
    [(x509.CertificateOk _)
      (test.assert-true false "malformed certificate accepted")
      (der.Error (der.InvalidValue) -1)]
    [(x509.CertificateErr error)
      (test.assert-true
        (and
          (>= error.offset 0)
          (<= error.offset (byte_buf.bytes-length bytes)))
        "error source range")
      error]))

(define (reject-extension [suffix : i64] [value : String]) : unit
  (let
    [bytes : byte_buf.ByteBuf (synthetic (extension suffix true value))]
    (expect-rejected (byte_buf.as-bytes (& bytes)))
    unit))

(define (version-tests) : unit
  (let
    [version : i64 1]
    (while (<= version 3)
      (let
        [prefix : String
          (cond
            [(= version 1) "020101"]
            [(= version 2) "a003020101020101"]
            [else "a003020102020101"])]
        [unique : String
          (if (= version 1)
            ""
            "8102008082020001")]
        [bytes : byte_buf.ByteBuf
          (synthetic-profile (byte_buf.new) prefix unique)]
        (match (x509.parse-der
          (byte_buf.as-bytes (& bytes))
          (x509.default-limits))
          [(x509.CertificateErr _)
            (test.assert-true false "certificate version/unique IDs rejected")]
          [(x509.CertificateOk certificate)
            (test.assert-i64-eq certificate.version version "version/default")]))
      (set! version (+ version 1))))
  (let
    [prefixes : (Array String 3)
      (array
        "a003020100020101"
        "a003020103020101"
        "a0030201020215008000000000000000000000000000000000000000")]
    [index : i64 0]
    (while (< index 3)
      (let
        [bytes : byte_buf.ByteBuf
          (synthetic-profile
            (byte_buf.new)
            (clone (array-ref prefixes index))
            "")]
        (expect-rejected (byte_buf.as-bytes (& bytes)))
        unit)
      (set! index (+ index 1))))
  (let
    [bytes : byte_buf.ByteBuf
      (synthetic-profile (byte_buf.new) "020101" "81020080")]
    (expect-rejected (byte_buf.as-bytes (& bytes)))
    unit))

(define (schema-negatives) : unit
  (reject-extension 19 "3003010100")
  (reject-extension 19 "3003020100")
  (reject-extension 19 "30060101ff0201ff")
  (reject-extension 15 "03020000")
  (reject-extension 15 "03020101")
  (reject-extension 15 "0303008000")
  (reject-extension 37 "3000")
  (reject-extension 37 "301406082b0601050507030106082b06010505070301")
  (reject-extension 14 "0400")
  (reject-extension 35 "3000")
  (reject-extension 35 "3003820101")
  (reject-extension 35 "3006800101800101")
  (reject-extension 17 "3000")
  (reject-extension 17 "30028100")
  (reject-extension 17 "30028200")
  (reject-extension 17 "30028600")
  (reject-extension 17 "30058703c00002")
  (reject-extension 17 "30038201ff")
  (reject-extension 17 "30028900")
  (reject-extension 17 "3004a4020500")
  (reject-extension 17 "3004a5020500")
  (reject-extension 30 "3000")
  (reject-extension 30 "3002a000")
  (reject-extension 30 "3009a1073005820361ff62")
  (reject-extension 30 "300ba009300782026162800101")
  (let
    [bytes : byte_buf.ByteBuf
      (synthetic (append (extension 19 true "3000") (extension 19 true "3000")))]
    (expect-rejected (byte_buf.as-bytes (& bytes)))
    unit))

(define (namespace-exclusions [ia5-tag : i64]) : unit
  (let
    [subtrees : byte_buf.ByteBuf
      (append
        (tlv 48 (tlv ia5-tag (byte_buf.new)))
        (append (tlv 48 (tlv 135 (zeros 8))) (tlv 48 (tlv 135 (zeros 32)))))]
    [value : byte_buf.ByteBuf (tlv 48 (tlv 161 subtrees))]
    [bytes : byte_buf.ByteBuf
      (synthetic (tlv 48 (append (hex "0603551d1e0101ff") (tlv 4 value))))]
    [fallback : x509.GeneralName
      (x509.GeneralName 0 (der.Range 0 0) (der.Range 0 0) (x509.NoAddress))]
    (match (x509.parse-der (byte_buf.as-bytes (& bytes)) (x509.default-limits))
      [(x509.CertificateErr error)
        (test.assert-i64-eq
          error.offset
          -1
          "empty IA5 namespace exclusion rejected")]
      [(x509.CertificateOk certificate)
        (test.assert-i64-eq
          (constraints.len (& certificate.name-constraints))
          3
          "all namespace exclusions")
        (let
          [empty : x509.Constraint
            (constraints.get
              (& certificate.name-constraints)
              0
              (x509.Constraint false fallback (x509.NoAddress)))]
          (test.assert-true empty.excluded "excluded empty IA5 base")
          (test.assert-i64-eq
            empty.base.kind
            (- ia5-tag 128)
            "empty IA5 CHOICE")
          (test.assert-i64-eq
            empty.base.value.length
            0
            "empty IA5 bytes retained"))
        (let
          [ipv4 : x509.Constraint
            (constraints.get
              (& certificate.name-constraints)
              1
              (x509.Constraint false fallback (x509.NoAddress)))]
          [ipv6 : x509.Constraint
            (constraints.get
              (& certificate.name-constraints)
              2
              (x509.Constraint false fallback (x509.NoAddress)))]
          (test.assert-true
            (and ipv4.excluded ipv6.excluded)
            "IP namespace exclusions")
          (test.assert-i64-eq ipv4.base.value.length 8 "IPv4 address and mask")
          (test.assert-i64-eq ipv6.base.value.length 32 "IPv6 address and mask")
          (match ipv4.mask
            [(x509.Address (ip.V4 mask))
              (test.assert-i64-eq
                (cast (ip.ipv4-octet (& mask) 0) : i64)
                0
                "zero IPv4 mask")]
            [_ (test.assert-true false "IPv4 mask lost type")])
          (match ipv6.mask
            [(x509.Address (ip.V6 mask))
              (test.assert-i64-eq
                (cast (ip.ipv6-segment (& mask) 7) : i64)
                0
                "zero IPv6 mask")]
            [_ (test.assert-true false "IPv6 mask lost type")]))])))

(define (other-names) : unit
  (let
    [bytes : byte_buf.ByteBuf
      (synthetic
        (extension
          17
          false
          "302b81016186016188022a03a505a1030c0141a00806022a03a0020500a40e300c310a300806035504030c0141"))]
    (match (x509.parse-der (byte_buf.as-bytes (& bytes)) (x509.default-limits))
      [(x509.CertificateErr error)
        (test.assert-i64-eq
          error.offset
          -1
          "supported non-DNS GeneralName rejected")]
      [(x509.CertificateOk certificate)
        (test.assert-i64-eq
          (names.len (& certificate.subject-alt-names))
          6
          "non-DNS CHOICE identity")])))

(define (unsupported-name) : unit
  (let
    [well-formed : byte_buf.ByteBuf
      (synthetic (extension 17 false "3004a3023000"))]
    [malformed : byte_buf.ByteBuf
      (synthetic (extension 17 false "3004a3020500"))]
    [error : der.Error (expect-rejected (byte_buf.as-bytes (& well-formed)))]
    (match error.kind
      [(der.UnsupportedGeneralName tag)
        (test.assert-i64-eq tag 3 "unsupported CHOICE tag")]
      [_
        (test.assert-true false "well-formed x400Address reported as malformed")])
    (let
      [bad : der.Error (expect-rejected (byte_buf.as-bytes (& malformed)))]
      (match bad.kind
        [(der.InvalidTag) unit]
        [_
          (test.assert-true
            false
            "malformed x400Address reported as unsupported")]))))

(define (der-negative [text : String] [offset : i64]) : unit
  (let
    [bytes : byte_buf.ByteBuf (hex text)]
    (match (der.validate (byte_buf.as-bytes (& bytes)) (der.default-limits))
      [(der.Valid) (test.assert-true false "malformed DER accepted")]
      [(der.Invalid error)
        (test.assert-i64-eq error.offset offset "DER offset")])))

(define (der-negatives) : unit
  (der-negative "30800000" 1)
  (der-negative "04817f" 1)
  (der-negative "04820080" 2)
  (der-negative "04888000000000000000" 9)
  (der-negative "1f1e00" 0)
  (der-negative "1f800100" 1)
  (der-negative "1f818181818181818181810100" 10)
  (der-negative "0200" 2)
  (der-negative "0202007f" 2)
  (der-negative "0202ff80" 2)
  (der-negative "0300" 2)
  (der-negative "030108" 2)
  (der-negative "03020301" 3)
  (der-negative "0600" 2)
  (der-negative "060180" 2)
  (der-negative "060181" 3)
  (der-negative "010101" 2)
  (der-negative "050100" 2)
  (der-negative "2400" 0)
  (der-negative "1000" 0)
  (der-negative "0000" 0)
  (der-negative "3106020102020101" 5)
  (der-negative "0c02c080" 2)
  (der-negative "0c03eda080" 4)
  (der-negative "1e02d800" 2)
  (der-negative "1c0400110000" 2)
  (der-negative "05000500" 2)
  (der-negative "3003020101ff" 5))

(define (pem-negative [payload : String] [offset : i64]) : unit
  (let
    [input : String
      (str_cat.str-cat
        "-----BEGIN CERTIFICATE-----\n"
        payload
        "\n-----END CERTIFICATE-----\n")]
    (match (pem.decode-certificates
      (byte_buf.str-as-bytes (& input))
      (pem.default-limits))
      [(pem.PemOk _) (test.assert-true false "malformed PEM accepted")]
      [(pem.PemErr error)
        (test.assert-i64-eq error.offset offset "PEM source offset")])))

(define (pem-tests) : unit
  (pem-negative "BQ@=" 30)
  (pem-negative "BQB=" 30)
  (pem-negative " BQ\t@= " 32)
  (pem-negative "BQA" 28)
  (let
    [input : String
      (str_cat.str-cat
        "explanatory text\r\n \t-----BEGIN CERTIFICATE-----\t\rB Q"
        (byte_buf.to-string (byte_buf.push (byte_buf.new) (cast 11 : u8)))
        "A"
        (byte_buf.to-string (byte_buf.push (byte_buf.new) (cast 12 : u8)))
        "=\r-----END CERTIFICATE----- \r\ntext\n-----BEGIN CERTIFICATE-----\nBQA=\n-----END CERTIFICATE-----")]
    (match (pem.decode-certificates
      (byte_buf.str-as-bytes (& input))
      (pem.default-limits))
      [(pem.PemErr _) (test.assert-true false "PEM whitespace rejected")]
      [(pem.PemOk bundle)
        (test.assert-i64-eq (blocks.len (& bundle)) 2 "multiple PEM blocks")]))
  (let
    [texts : (Array String 7)
      (array
        "-----BEGIN certificate-----\nBQA=\n-----END certificate-----"
        "-----BEGIN PUBLIC KEY-----\nBQA=\n-----END PUBLIC KEY-----"
        "-----BEGIN CERTIFICATE-----\nBQA=\n-----END PUBLIC KEY-----"
        "-----END CERTIFICATE-----"
        "-----BEGIN CERTIFICATE-----\nBQA="
        "-----BEGIN CERTIFICATE-----\n-----BEGIN CERTIFICATE-----"
        "-----BEGIN CERTIFICATE-----\n\n-----END CERTIFICATE-----")]
    [index : i64 0]
    (while (< index 7)
      (let
        [text : String (clone (array-ref texts index))]
        (match (pem.decode-certificates
          (byte_buf.str-as-bytes (& text))
          (pem.default-limits))
          [(pem.PemOk _) (test.assert-true false "invalid boundary accepted")]
          [(pem.PemErr _) unit]))
      (set! index (+ index 1)))))

(define (time-value [text : String] [tag : i64] [expected : i64]) : unit
  (match (time.parse (byte_buf.str-as-bytes (& text)) tag 0)
    [(time.TimeErr _)
      (test.assert-true false "valid certificate time rejected")]
    [(time.TimeOk instant)
      (test.assert-i64-eq instant.epoch-ms expected "time epoch milliseconds")]))

(define (time-tests) : unit
  (time-value "500101000000Z" 23 -631152000000)
  (time-value "491231235959Z" 23 2524607999000)
  (time-value "00010101000000Z" 24 -62135596800000)
  (time-value "99991231235959Z" 24 253402300799000)
  (time-value "20000229000000Z" 24 951782400000)
  (let
    [bad : (Array String 13)
      (array
        "00000101000000Z"
        "19000229000000Z"
        "20010229000000Z"
        "20000431000000Z"
        "20000001000000Z"
        "20001301000000Z"
        "20000100000000Z"
        "20000101240000Z"
        "20000101006000Z"
        "20000101000060Z"
        "20000101000000+0000"
        "200001010000Z"
        "20000101000000.0Z")]
    [index : i64 0]
    (while (< index 13)
      (let
        [text : String (clone (array-ref bad index))]
        (match (time.parse (byte_buf.str-as-bytes (& text)) 24 100)
          [(time.TimeOk _) (test.assert-true false "invalid time accepted")]
          [(time.TimeErr error)
            (test.assert-true (>= error.offset 100) "absolute time offset")]))
      (set! index (+ index 1))))
  ; Every supported year: consecutive January instants differ by a real year.
  (let
    [year : i64 1]
    [expected : i64 -62135596800000]
    (while (<= year 9999)
      (let
        [digits : String (string.int->string year)]
        [prefix : String
          (cond
            [(< year 10) "000"]
            [(< year 100) "00"]
            [(< year 1000) "0"]
            [else ""])]
        (time-value (str_cat.str-cat prefix digits "0101000000Z") 24 expected))
      (let
        [days : i64
          (if (or (= (% year 400) 0) (and (= (% year 4) 0) (!= (% year 100) 0)))
            366
            365)]
        (set! expected (+ expected (* days 86400000))))
      (set! year (+ year 1)))))

(define (reject-with-limits [bytes : (& bytes bytes)] [limits : x509.Limits]) : unit
  (match (x509.parse-der bytes limits)
    [(x509.CertificateOk _)
      (test.assert-true false "certificate budget ignored")]
    [(x509.CertificateErr error)
      (match error.kind
        [(der.LimitExceeded) unit]
        [(der.InvalidLimit) unit]
        [_ (test.assert-true false "unexpected budget error")])]))

(define (budget-tests) : unit
  (let
    [bytes : byte_buf.ByteBuf (hex-bytes (& rsa-hex))]
    [limits : x509.Limits (x509.default-limits)]
    [work : der.Cursor (der.cursor 0 (byte_buf.len bytes))]
    (set! limits.der.max-bytes (- (byte_buf.len bytes) 1))
    (reject-with-limits (byte_buf.as-bytes (& bytes)) limits)
    (set! limits (x509.default-limits))
    (set! limits.max-extensions 7)
    (reject-with-limits (byte_buf.as-bytes (& bytes)) limits)
    (set! limits (x509.default-limits))
    (set! limits.max-names 4)
    (reject-with-limits (byte_buf.as-bytes (& bytes)) limits)
    (set! limits (x509.default-limits))
    (set! limits.der.max-depth 6)
    (reject-with-limits (byte_buf.as-bytes (& bytes)) limits)
    (set! limits (x509.default-limits))
    (set! limits.der.max-depth 65)
    (reject-with-limits (byte_buf.as-bytes (& bytes)) limits)
    (set! limits (x509.default-limits))
    (der.validate!
      (byte_buf.as-bytes (& bytes))
      (der.Range 0 (byte_buf.len bytes))
      limits.der
      0
      (&mut work))
    (test.assert-false work.failed "outer DER budget control")
    (set! limits.der.max-nodes work.nodes)
    (reject-with-limits (byte_buf.as-bytes (& bytes)) limits))
  (let
    [input : String
      "-----BEGIN CERTIFICATE-----\nBQA=\n-----END CERTIFICATE-----\n"]
    [field : i64 0]
    (while (< field 4)
      (let
        [limits : pem.Limits (pem.default-limits)]
        (cond
          [(= field 0)
            (set! limits.max-input-bytes (- (string-length input) 1))]
          [(= field 1) (set! limits.max-certificate-bytes 1)]
          [(= field 2) (set! limits.max-total-bytes 1)]
          [else (set! limits.max-certificates 0)])
        (match (pem.decode-certificates
          (byte_buf.str-as-bytes (& input))
          limits)
          [(pem.PemOk _) (test.assert-true false "PEM budget ignored")]
          [(pem.PemErr error)
            (match error.kind
              [(der.LimitExceeded) unit]
              [_ (test.assert-true false "PEM budget error kind")])]))
      (set! field (+ field 1)))))

(define (error-code [kind : der.ErrorKind]) : i64
  (match kind
    [(der.InvalidLimit) 0]
    [(der.LimitExceeded) 1]
    [(der.Truncated) 2]
    [(der.InvalidTag) 3]
    [(der.InvalidLength) 4]
    [(der.InvalidValue) 5]
    [(der.TrailingData) 6]
    [(der.Duplicate) 7]
    [(der.AlgorithmMismatch) 8]
    [(der.InvalidTime) 9]
    [(der.InvalidEnvelope) 10]
    [(der.InvalidBase64) 11]
    [(der.UnsupportedGeneralName tag) (+ 100 tag)]
    [(der.UnsupportedType tag) (+ 200 tag)]))

(define (outcome [input : (& input bytes)]) : der.Error
  (match (x509.parse-der input (x509.default-limits))
    [(x509.CertificateErr error) error]
    [(x509.CertificateOk certificate)
      (test.assert-i64-eq
        (byte_buf.len certificate.der)
        (byte_buf.bytes-length input)
        "owned complete DER")
      (der.Error (der.InvalidValue) -1)]))

(define (mutation-corpus) : unit
  (let
    [original : byte_buf.ByteBuf (hex-bytes (& rsa-hex))]
    [length : i64 (byte_buf.len original)]
    [cut : i64 0]
    [seed : i64 6987]
    [index : i64 0]
    [accepted : i64 0]
    [rejected : i64 0]
    ; Every truncated prefix must fail; no partial certificate escapes.
    (while (< cut length)
      (let
        [error : der.Error
          (expect-rejected
            (byte_buf.bytes-slice-view (byte_buf.as-bytes (& original)) 0 cut))]
        (test.assert-true (<= error.offset cut) "truncated prefix offset"))
      (set! cut (+ cut 1)))
    ; 512 fixed-seed one-byte mutations. Signature/name/key changes can remain
    ; well-encoded; parser acceptance is deliberately not authenticity.
    (while (< index 512)
      (set! seed (% (* seed 48271) 2147483647))
      (let
        [position : i64 (% seed length)]
        [bytes : byte_buf.ByteBuf
          (byte_buf.from-bytes (byte_buf.as-bytes (& original)))]
        [old : i64
          (cast
            (byte_buf.bytes-ref (byte_buf.as-bytes (& bytes)) position)
            : i64)]
        (set! seed (% (* seed 48271) 2147483647))
        (byte_buf.bytes-set!
          (byte_buf.as-mut-bytes (&mut bytes))
          position
          (cast (bit-xor old (+ 1 (% seed 255))) : u8))
        (let
          [first : der.Error (outcome (byte_buf.as-bytes (& bytes)))]
          [second : der.Error (outcome (byte_buf.as-bytes (& bytes)))]
          (test.assert-i64-eq
            first.offset
            second.offset
            "mutation deterministic offset")
          (test.assert-i64-eq
            (error-code first.kind)
            (error-code second.kind)
            "mutation deterministic kind")
          (if (= first.offset -1)
            (set! accepted (+ accepted 1))
            (begin
              (test.assert-true
                (and (>= first.offset 0) (<= first.offset length))
                "mutation offset range")
              (set! rejected (+ rejected 1))))))
      (set! index (+ index 1)))
    (test.assert-true (> accepted 0) "non-authenticating mutation control")
    (test.assert-true (> rejected 0) "negative mutation coverage"))
  (let
    [seed : i64 7468]
    [index : i64 0]
    (while (< index 256)
      (set! seed (% (* seed 48271) 2147483647))
      (let
        [bytes : byte_buf.ByteBuf (byte_buf.from-string (clone rsa-pem))]
        [position : i64 (% seed (byte_buf.len bytes))]
        (set! seed (% (* seed 48271) 2147483647))
        (byte_buf.bytes-set!
          (byte_buf.as-mut-bytes (&mut bytes))
          position
          (cast (% seed 256) : u8))
        (match (x509.parse-pem
          (byte_buf.as-bytes (& bytes))
          (x509.default-limits))
          [(x509.CertificatesOk bundle)
            (test.assert-i64-eq
              (certificates.len (& bundle))
              1
              "mutation PEM count")]
          [(x509.CertificatesErr error)
            (test.assert-true
              (and
                (>= error.error.offset 0)
                (<= error.error.offset (byte_buf.len bytes)))
              "PEM mutation offset range")]))
      (set! index (+ index 1)))))

(define (replace-byte [bytes : (& bytes bytes)] [offset : i64] [value : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.from-bytes bytes)]
    (byte_buf.bytes-set!
      (byte_buf.as-mut-bytes (&mut out))
      offset
      (cast value : u8))
    out))

(define (custom-attribute) : unit
  (let
    [original : byte_buf.ByteBuf (synthetic (byte_buf.new))]
    (match (x509.parse-der
      (byte_buf.as-bytes (& original))
      (x509.default-limits))
      [(x509.CertificateErr _)
        (test.assert-true false "custom attribute baseline")]
      [(x509.CertificateOk certificate)
        (let
          [start : i64 certificate.subject.encoded.start]
          [bytes : byte_buf.ByteBuf
            (byte_buf.from-bytes (byte_buf.as-bytes (& original)))]
          ; Private OID 1.2.3.4, INTEGER 65. AttributeValue is ANY, so a
          ; well-encoded unknown attribute must retain its value unchanged.
          (byte_buf.bytes-set!
            (byte_buf.as-mut-bytes (&mut bytes))
            (+ start 8)
            (cast 42 : u8))
          (byte_buf.bytes-set!
            (byte_buf.as-mut-bytes (&mut bytes))
            (+ start 9)
            (cast 3 : u8))
          (byte_buf.bytes-set!
            (byte_buf.as-mut-bytes (&mut bytes))
            (+ start 10)
            (cast 4 : u8))
          (byte_buf.bytes-set!
            (byte_buf.as-mut-bytes (&mut bytes))
            (+ start 11)
            (cast 2 : u8))
          (match (x509.parse-der
            (byte_buf.as-bytes (& bytes))
            (x509.default-limits))
            [(x509.CertificateErr error)
              (test.assert-i64-eq
                error.offset
                -1
                "valid custom AttributeValue rejected")]
            [(x509.CertificateOk parsed)
              (let
                [attribute : x509.Attribute
                  (attributes.get
                    (& parsed.subject.attributes)
                    0
                    (x509.Attribute
                      0
                      (der.Range 0 0)
                      (der.Range 0 0)
                      0
                      0
                      false
                      (der.Range 0 0)))]
                (test.assert-i64-eq
                  attribute.tag
                  2
                  "custom attribute value tag")
                (test.assert-i64-eq
                  attribute.tag-class
                  0
                  "custom attribute value class")
                (test.assert-false
                  attribute.constructed
                  "custom attribute primitive")
                (test.assert-i64-eq
                  (cast
                    (byte_buf.bytes-ref
                      (x509.view (& parsed) attribute.value)
                      0)
                    : i64)
                  65
                  "custom attribute exact value"))]))])))

(define (field-negatives) : unit
  (let
    [bytes : byte_buf.ByteBuf (hex-bytes (& rsa-hex))]
    (match (x509.parse-der (byte_buf.as-bytes (& bytes)) (x509.default-limits))
      [(x509.CertificateErr _)
        (test.assert-true false "negative fixture baseline")]
      [(x509.CertificateOk certificate)
        (let
          [negative : byte_buf.ByteBuf
            (replace-byte
              (byte_buf.as-bytes (& bytes))
              certificate.serial.start
              255)]
          [zero : byte_buf.ByteBuf
            (replace-byte
              (byte_buf.as-bytes (& bytes))
              certificate.serial.start
              0)]
          [algorithm : byte_buf.ByteBuf
            (replace-byte
              (byte_buf.as-bytes (& bytes))
              (-
                (+
                  certificate.signature-algorithm.oid.start
                  certificate.signature-algorithm.oid.length)
                1)
              12)]
          [error : der.Error
            (expect-rejected (byte_buf.as-bytes (& algorithm)))]
          (expect-rejected (byte_buf.as-bytes (& negative)))
          (expect-rejected (byte_buf.as-bytes (& zero)))
          (match error.kind
            [(der.AlgorithmMismatch) unit]
            [_
              (test.assert-true false "inner/outer algorithm mismatch category")]))
        (let
          [trailing : byte_buf.ByteBuf
            (byte_buf.push
              (byte_buf.from-bytes (byte_buf.as-bytes (& bytes)))
              (cast 0 : u8))]
          (expect-rejected (byte_buf.as-bytes (& trailing)))
          unit)]))
  (let
    [bundle : String (str_cat.str-cat (clone rsa-pem) "text\n" (clone rsa-pem))]
    [bad : String
      (str_cat.str-cat
        (clone rsa-pem)
        "-----BEGIN CERTIFICATE-----\nBQA=\n-----END CERTIFICATE-----\n")]
    (match (x509.parse-pem
      (byte_buf.str-as-bytes (& bundle))
      (x509.default-limits))
      [(x509.CertificatesOk certs)
        (test.assert-i64-eq (certificates.len (& certs)) 2 "certificate bundle")]
      [(x509.CertificatesErr _)
        (test.assert-true false "certificate bundle rejected")])
    (match (x509.parse-pem
      (byte_buf.str-as-bytes (& bad))
      (x509.default-limits))
      [(x509.CertificatesOk _)
        (test.assert-true false "partial bundle escaped")]
      [(x509.CertificatesErr error)
        (test.assert-i64-eq error.certificate-index 1 "bad bundle block index")
        (test.assert-i64-eq
          error.source.start
          (string-length rsa-pem)
          "bad bundle source envelope")])))

(define (fixture [text : (& text str)] [tbs-length : i64] [tbs-hash : String]) : unit
  (let
    [bytes : byte_buf.ByteBuf (hex-bytes text)]
    (match (x509.parse-der (byte_buf.as-bytes (& bytes)) (x509.default-limits))
      [(x509.CertificateErr error)
        (test.assert-i64-eq error.offset -1 "independent certificate rejected")]
      [(x509.CertificateOk certificate)
        (test.assert-i64-eq certificate.version 3 "version")
        (test.assert-i64-eq certificate.serial.length 1 "serial width")
        (test.assert-i64-eq
          (cast
            (byte_buf.bytes-ref
              (x509.view (& certificate) certificate.serial)
              0)
            : i64)
          42
          "serial")
        (test.assert-i64-eq
          (extensions.len (& certificate.extensions))
          8
          "extensions")
        (test.assert-i64-eq
          (names.len (& certificate.subject-alt-names))
          5
          "SAN names")
        (test.assert-i64-eq
          (constraints.len (& certificate.name-constraints))
          3
          "name constraints")
        (test.assert-i64-eq
          (ranges.len (& certificate.extended-key-usage))
          2
          "EKU")
        (test.assert-i64-eq certificate.key-usage 97 "key usage")
        (test.assert-true certificate.basic-constraints.ca "CA")
        (test.assert-i64-eq
          certificate.basic-constraints.path-length
          2
          "path length")
        (test.assert-i64-eq certificate.subject-key-id.length 20 "SKI")
        (test.assert-i64-eq certificate.authority-key-id.key-id.length 20 "AKI")
        (let
          [unknown : x509.Extension
            (extensions.get
              (& certificate.extensions)
              7
              (x509.Extension
                (der.Range 0 0)
                false
                (der.Range 0 0)
                (der.Range 0 0)
                0))]
          (test.assert-true unknown.critical "unknown critical retained")
          (test.assert-i64-eq unknown.kind -1 "unknown OID retained"))
        (let
          [address : x509.GeneralName
            (names.get
              (& certificate.subject-alt-names)
              1
              (x509.GeneralName
                0
                (der.Range 0 0)
                (der.Range 0 0)
                (x509.NoAddress)))]
          (match address.address
            [(x509.Address (ip.V4 ipv4))
              (test.assert-i64-eq
                (cast (ip.ipv4-octet (& ipv4) 0) : i64)
                192
                "typed SAN address")]
            [_ (test.assert-true false "SAN lost canonical IPv4 type")]))
        (test.assert-i64-eq certificate.not-before.year 2026 "validity start")
        (test.assert-i64-eq certificate.not-after.year 2027 "validity end")
        (test.assert-i64-eq certificate.tbs.start 4 "independent TBS offset")
        (test.assert-i64-eq
          (der.compare-ranges
            (byte_buf.as-bytes (& bytes))
            certificate.tbs-signature-algorithm.encoded
            certificate.signature-algorithm.encoded)
          0
          "both exact signature identifiers")
        (test.assert-i64-eq
          certificate.tbs.length
          tbs-length
          "independent TBS length")
        (match (sha.digest (x509.view (& certificate) certificate.tbs))
          [(sha.Sha256FinalizeErr _) (test.assert-true false "TBS digest")]
          [(sha.Sha256FinalizeOk digest)
            (let
              [actual : String (sha.to-hex (& digest))]
              (test.assert-string-eq
                (& actual)
                (& tbs-hash)
                "independent TBS hash"))])
        (let
          [original : (& bytes bytes) (byte_buf.as-bytes (& bytes))]
          [owned : (& certificate bytes)
            (x509.view (& certificate) certificate.tbs)]
          [index : i64 0]
          (while (< index certificate.tbs.length)
            (test.assert-i64-eq
              (cast (byte_buf.bytes-ref owned index) : i64)
              (cast
                (byte_buf.bytes-ref original (+ certificate.tbs.start index))
                : i64)
              "exact TBS bytes")
            (set! index (+ index 1))))
        (match (x509.parse-pem
          (byte_buf.str-as-bytes (& rsa-pem))
          (x509.default-limits))
          [(x509.CertificatesErr error)
            (test.assert-i64-eq
              error.error.offset
              -1
              "independent PEM rejected")]
          [(x509.CertificatesOk bundle)
            (test.assert-i64-eq (certificates.len (& bundle)) 1 "PEM count")])])))

(define (service-certificate [san : byte_buf.ByteBuf]) : x509.Certificate
  (let
    [extensions : byte_buf.ByteBuf
      (tlv 48 (append (hex "0603551d11") (tlv 4 (tlv 48 san))))]
    [encoded : byte_buf.ByteBuf (synthetic extensions)]
    (match (x509.parse-der
      (byte_buf.as-bytes (& encoded))
      (x509.default-limits))
      [(x509.CertificateOk certificate) certificate]
      [(x509.CertificateErr _)
        (test.assert-true false "valid identity certificate")
        (init : x509.Certificate)])))

(define (service-dns [text : String]) : byte_buf.ByteBuf
  (tlv 130 (byte_buf.from-string text)))

(define (service-ref [text : (& text str)]) : x509.ServiceReference
  (match (x509.service-reference text)
    [(x509.ServiceReferenceOk reference) reference]
    [(x509.ServiceReferenceErr _)
      (test.assert-true false "valid service reference")
      (x509.Ip (ip.V4 (ip.ipv4 0 0 0 0)))]))

(define (service-refs [text : (& text str)]) : x509.ServiceReferences
  (let
    [references : x509.ServiceReferences (x509.service-references-new)]
    (match (x509.service-reference-add!
      (&mut references)
      (service-ref text)
      (x509.service-identity-default-limits))
      [(x509.ServiceReferenceAdded) unit]
      [(x509.ServiceReferenceAddErr _)
        (test.assert-true false "append reference")])
    references))

(define (service-match
  [certificate : (& certificate x509.Certificate)]
  [reference : String]
  [expected-san : i64]) : unit
  (let
    [references : x509.ServiceReferences (service-refs (& reference))]
    (match (x509.service-identity
      certificate
      (& references)
      (x509.service-identity-default-limits))
      [(x509.ServiceIdentityMatch reference-index san-index)
        (test.assert-i64-eq reference-index 0 "matched reference index")
        (test.assert-i64-eq san-index expected-san "matched SAN index")]
      [(x509.ServiceIdentityErr _)
        (test.assert-true false "identity must match")])))

(define (service-error
  [certificate : (& certificate x509.Certificate)]
  [references : (& references x509.ServiceReferences)]
  [limits : x509.ServiceIdentityLimits]
  [kind : x509.ServiceIdentityErrorKind]) : unit
  (match (x509.service-identity certificate references limits)
    [(x509.ServiceIdentityMatch _ _)
      (test.assert-true false "unexpected identity match")]
    [(x509.ServiceIdentityErr error)
      (test.assert-true (= error.kind kind) "identity failure category")]))

(define (service-mismatch
  [certificate : (& certificate x509.Certificate)]
  [reference : String]) : unit
  (let
    [references : x509.ServiceReferences (service-refs (& reference))]
    (service-error
      certificate
      (& references)
      (x509.service-identity-default-limits)
      (x509.IdentityMismatch))))

(define (service-input-error
  [text : String]
  [kind : x509.ServiceIdentityErrorKind]) : unit
  (match (x509.service-reference (& text))
    [(x509.ServiceReferenceOk _)
      (test.assert-true false "invalid reference accepted")]
    [(x509.ServiceReferenceErr error)
      (test.assert-true (= error.kind kind) "reference failure category")]))

(define (service-repeat [byte : u8] [count : i64]) : String
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity count)]
    [index : i64 0]
    (while (< index count)
      (set! out (byte_buf.push out byte))
      (set! index (+ index 1)))
    (byte_buf.to-string out)))

(define (service-dns-tests) : unit
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "EXample.Test."))]
    (service-match (& certificate) "example.test" 0)
    (service-match (& certificate) "ExAmPlE.TeSt." 0)
    (service-mismatch (& certificate) "example.other")
    (service-mismatch (& certificate) "www.example.test")
    (service-mismatch (& certificate) "192.0.2.1"))
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "XN--BCHER-KVA.Test"))]
    (service-match (& certificate) "xn--bcher-kva.test." 0))
  (let
    [certificate : x509.Certificate (service-certificate (service-dns "COM"))]
    (service-match (& certificate) "com." 0))
  (service-input-error "bücher.test" (x509.InternationalizedNameUnsupported))
  (service-input-error
    (str_cat.str-cat (service-repeat 255 1) ".test")
    (x509.InternationalizedNameUnsupported))
  (service-input-error "" (x509.InvalidDnsName))
  (service-input-error "." (x509.InvalidDnsName))
  (service-input-error ".test" (x509.InvalidDnsName))
  (service-input-error "test..name" (x509.InvalidDnsName))
  (service-input-error "test.." (x509.InvalidDnsName))
  (service-input-error "-test.name" (x509.InvalidDnsName))
  (service-input-error "test-.name" (x509.InvalidDnsName))
  (service-input-error "xn--.test" (x509.InvalidDnsName))
  (service-input-error "ab--cd.test" (x509.InvalidDnsName))
  (service-input-error "*.test" (x509.InvalidDnsName))
  (service-input-error "test.*" (x509.InvalidDnsName))
  (service-input-error "test_1.name" (x509.InvalidDnsName))
  (service-input-error
    (str_cat.str-cat "test" (service-repeat 0 1) ".name")
    (x509.InvalidDnsName))
  (service-input-error
    (str_cat.str-cat "test" (service-repeat 31 1) ".name")
    (x509.InvalidDnsName))
  (service-input-error
    (str_cat.str-cat "test" (service-repeat 127 1) ".name")
    (x509.InvalidDnsName))
  (service-input-error "[::1]" (x509.InvalidDnsName))
  (service-input-error "fe80::1%eth0" (x509.InvalidDnsName))
  (service-input-error "192.0.2.1:443" (x509.InvalidDnsName))
  (service-input-error "192.0.2.0/24" (x509.InvalidDnsName))
  (let
    [label : String (service-repeat 97 63)]
    [maximum : String
      (str_cat.str-cat
        (clone label)
        "."
        (clone label)
        "."
        (clone label)
        "."
        (service-repeat 98 61))]
    [certificate : x509.Certificate
      (service-certificate (service-dns (clone maximum)))]
    (service-match (& certificate) (clone maximum) 0)
    (service-match (& certificate) (str_cat.str-cat (clone maximum) ".") 0)
    (service-input-error
      (str_cat.str-cat (clone maximum) "a")
      (x509.DnsNameTooLong))
    (service-input-error
      (str_cat.str-cat (clone maximum) "a.")
      (x509.DnsNameTooLong))
    (service-input-error (service-repeat 97 64) (x509.InvalidDnsName))
    (let
      [other : String
        (str_cat.str-cat
          (clone label)
          "."
          (clone label)
          "."
          (clone label)
          "."
          (service-repeat 98 60)
          "c")]
      (service-mismatch (& certificate) other))))

(define (service-wildcard-tests) : unit
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "*.EXAMPLE.test."))]
    (service-match (& certificate) "www.example.test" 0)
    (service-match (& certificate) "xn--bcher-kva.example.test." 0)
    (service-mismatch (& certificate) "example.test")
    (service-mismatch (& certificate) "a.b.example.test")
    (let
      [references : x509.ServiceReferences (service-refs "www.example.test")]
      [limits : x509.ServiceIdentityLimits
        (x509.service-identity-default-limits)]
      (set! limits.wildcards (x509.DisallowWildcards))
      (service-error
        (& certificate)
        (& references)
        limits
        (x509.NoSupportedPresentedIdentifier))))
  ; RFC matching deliberately does not enforce PSL policy or count suffix labels.
  (let
    [certificate : x509.Certificate (service-certificate (service-dns "*.com"))]
    (service-match (& certificate) "example.com" 0))
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "*.co.uk"))]
    (service-match (& certificate) "example.co.uk" 0))
  (let
    [invalid : (Array String 11)
      (array
        "*"
        "*foo.test"
        "foo*.test"
        "f*o.test"
        "a.*.test"
        "*.*.test"
        "**.test"
        "-a.test"
        "ab--cd.test"
        "xn--.test"
        "a..test")]
    [index : i64 0]
    (while (< index 11)
      (let
        [certificate : x509.Certificate
          (service-certificate (service-dns (clone (array-ref invalid index))))]
        [references : x509.ServiceReferences (service-refs "a.test")]
        (service-error
          (& certificate)
          (& references)
          (x509.service-identity-default-limits)
          (x509.NoSupportedPresentedIdentifier)))
      (set! index (+ index 1))))
  (let
    [san : byte_buf.ByteBuf
      (append (service-dns "*foo.test") (service-dns "wrong.test"))]
    (set! san (append san (service-dns "*.example.test")))
    (set!
      san
      (append san (tlv 134 (byte_buf.from-string "https://irrelevant.test"))))
    (set! san (append san (service-dns "a..test")))
    (let
      [certificate : x509.Certificate (service-certificate san)]
      (service-match (& certificate) "www.example.test" 2)))
  (let
    [certificate : x509.Certificate
      (service-certificate
        (append (service-dns "a..test") (service-dns "exact.test")))]
    (service-match (& certificate) "exact.test" 1)))

(define (service-ip-tests) : unit
  (let
    [san : byte_buf.ByteBuf
      (append (service-dns "192.0.2.1") (tlv 135 (hex "c0000201")))]
    [certificate : x509.Certificate (service-certificate san)]
    (service-match (& certificate) "192.0.2.1" 1)
    (service-input-error "192.0.2.1." (x509.InvalidDnsName))
    (service-mismatch (& certificate) "192.0.2.2")
    (service-mismatch (& certificate) "::ffff:192.0.2.1")
    (service-mismatch (& certificate) "192.000.2.1")
    (service-mismatch (& certificate) "3221225985")
    (service-mismatch (& certificate) "0xc0000201")
    (service-mismatch (& certificate) "0300.0.2.1"))
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "192.0.2.1"))]
    (service-mismatch (& certificate) "192.0.2.1"))
  (let
    [certificate : x509.Certificate
      (service-certificate (tlv 135 (hex "20010db8000000000000000000000001")))]
    (service-match (& certificate) "2001:db8::1" 0)
    (service-match (& certificate) "2001:0DB8:0:0:0:0:0:0001" 0)
    (service-mismatch (& certificate) "2001:db8::2")
    (service-mismatch (& certificate) "192.0.2.1"))
  (let
    [certificate : x509.Certificate
      (service-certificate (tlv 135 (hex "00000000000000000000ffffc0000201")))]
    (service-match (& certificate) "::ffff:c000:201" 0)
    (service-match (& certificate) "0:0:0:0:0:ffff:192.0.2.1" 0)
    (service-mismatch (& certificate) "192.0.2.1"))
  ; Wrong-length IP and malformed SAN DER fail at the parser boundary.
  (let
    [encoded : byte_buf.ByteBuf
      (synthetic (extension 17 false "30058703c00002"))]
    [_error : der.Error (expect-rejected (byte_buf.as-bytes (& encoded)))]
    unit)
  (let
    [encoded : byte_buf.ByteBuf (synthetic (extension 17 false "3080"))]
    [_error : der.Error (expect-rejected (byte_buf.as-bytes (& encoded)))]
    unit))

(define (service-mixed-tests) : unit
  (let
    [san : byte_buf.ByteBuf
      (tlv 134 (byte_buf.from-string "https://wanted.test"))]
    (set! san (append san (tlv 135 (hex "c0000201"))))
    (set! san (append san (service-dns "wrong.test")))
    (set!
      san
      (append
        san
        (service-dns (str_cat.str-cat "a" (service-repeat 0 1) ".test"))))
    (set! san (append san (service-dns "wanted.test")))
    (set! san (append san (tlv 135 (hex "c0000202"))))
    (let
      [certificate : x509.Certificate (service-certificate san)]
      [references : x509.ServiceReferences (service-refs "wanted.test")]
      [before : i64 (profile.alloc-total)]
      [result : x509.ServiceIdentityResult
        (x509.service-identity
          (& certificate)
          (& references)
          (x509.service-identity-default-limits))]
      [after : i64 (profile.alloc-total)]
      (cfg
        compile-profile
        (test.assert-true (> before 0) "allocation counters active")
        unit)
      (test.assert-i64-eq after before "identity search allocates nothing")
      (match result
        [(x509.ServiceIdentityMatch reference-index san-index)
          (test.assert-i64-eq reference-index 0 "mixed reference index")
          (test.assert-i64-eq san-index 4 "mixed SAN index")]
        [(x509.ServiceIdentityErr _) (test.assert-true false "mixed SAN match")])
      (service-match (& certificate) "192.0.2.2" 5)))
  (let
    [reference : x509.ServiceReference (x509.Dns (x509.ServiceDnsName ""))]
    [references : x509.ServiceReferences (x509.service-references-new)]
    (match (x509.service-reference-add!
      (&mut references)
      reference
      (x509.service-identity-default-limits))
      [(x509.ServiceReferenceAdded)
        (test.assert-true false "empty DNS reference accepted")]
      [(x509.ServiceReferenceAddErr error)
        (test.assert-true
          (= error.kind (x509.InvalidReference))
          "empty reference failure")]))
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "wanted.test"))]
    [references : x509.ServiceReferences (service-refs "wrong.test")]
    (service-error
      (& certificate)
      (& references)
      (x509.service-identity-default-limits)
      (x509.IdentityMismatch))))

(define (service-record-error [input : String]) : unit
  (let
    [references : x509.ServiceReferences (x509.service-references-new)]
    [record : x509.ServiceReference
      (x509.Dns (x509.ServiceDnsName (clone input)))]
    [certificate : x509.Certificate (init : x509.Certificate)]
    (match (x509.service-reference-add!
      (&mut references)
      record
      (x509.service-identity-default-limits))
      [(x509.ServiceReferenceAdded)
        (test.assert-true false "invalid record inserted")]
      [(x509.ServiceReferenceAddErr error)
        (test.assert-true
          (= error.kind (x509.InvalidReference))
          "record insertion error")])
    (test.assert-i64-eq references.length 0 "failed append unchanged")
    (set!
      (array-ref references.values 0)
      (x509.Dns (x509.ServiceDnsName input)))
    (set! references.length 1)
    (service-error
      (& certificate)
      (& references)
      (x509.service-identity-default-limits)
      (x509.InvalidReference))))

(define (service-bound-tests) : unit
  (service-record-error "")
  (service-record-error "UPPER.test")
  (service-record-error "example.test.")
  (service-record-error "a..test")
  (service-record-error "192.0.2.1")
  (service-record-error (service-repeat 97 255))
  (service-record-error (service-repeat 255 1))
  (let
    [oversized : String (service-repeat 97 1048576)]
    [before : i64 (profile.alloc-total)]
    [result : x509.ServiceReferenceResult
      (x509.service-reference (& oversized))]
    [after : i64 (profile.alloc-total)]
    (test.assert-i64-eq
      after
      before
      "oversized reference preflight allocates nothing")
    (match result
      [(x509.ServiceReferenceOk _)
        (test.assert-true false "oversized reference accepted")]
      [(x509.ServiceReferenceErr error)
        (test.assert-true
          (= error.kind (x509.DnsNameTooLong))
          "oversized reference error")
        (test.assert-i64-eq error.offset 254 "oversized reference bound")])
    (service-input-error (str_cat.str-cat oversized ":") (x509.DnsNameTooLong)))
  (let
    [certificate : x509.Certificate
      (service-certificate (service-dns "match.test"))]
    [references : x509.ServiceReferences (x509.service-references-new)]
    [limits : x509.ServiceIdentityLimits (x509.service-identity-default-limits)]
    (service-error (& certificate) (& references) limits (x509.EmptyReferences))
    (set! references (service-refs "other.test"))
    (match (x509.service-reference-add!
      (&mut references)
      (service-ref "match.test")
      limits)
      [(x509.ServiceReferenceAdded) unit]
      [(x509.ServiceReferenceAddErr _)
        (test.assert-true false "second reference")])
    (match (x509.service-identity (& certificate) (& references) limits)
      [(x509.ServiceIdentityMatch reference-index san-index)
        (test.assert-i64-eq reference-index 1 "second reference identity")
        (test.assert-i64-eq san-index 0 "first SAN")]
      [(x509.ServiceIdentityErr _)
        (test.assert-true false "second reference match")])
    (set! limits.max-references 1)
    (service-error (& certificate) (& references) limits (x509.ReferenceLimit))
    (set! limits.max-references 0)
    (match (x509.service-reference-add!
      (&mut references)
      (service-ref "extra.test")
      limits)
      [(x509.ServiceReferenceAdded)
        (test.assert-true false "append exceeded bound")]
      [(x509.ServiceReferenceAddErr error)
        (test.assert-true
          (= error.kind (x509.ReferenceLimit))
          "append bound error")])
    (set! limits (x509.service-identity-default-limits))
    (set! limits.max-presented 0)
    (service-error (& certificate) (& references) limits (x509.PresentedLimit))
    (set! limits.max-presented -1)
    (service-error
      (& certificate)
      (& references)
      limits
      (x509.InvalidIdentityLimits))
    (set! limits.max-presented 4097)
    (service-error
      (& certificate)
      (& references)
      limits
      (x509.InvalidIdentityLimits))
    (set! limits (x509.service-identity-default-limits))
    (set! limits.max-references 65)
    (service-error
      (& certificate)
      (& references)
      limits
      (x509.InvalidIdentityLimits)))
  (let
    [encoded : byte_buf.ByteBuf (synthetic (byte_buf.new))]
    [references : x509.ServiceReferences (service-refs "A")]
    (match (x509.parse-der
      (byte_buf.as-bytes (& encoded))
      (x509.default-limits))
      [(x509.CertificateOk certificate)
        ; The synthetic certificate's Common Name is A. It is never consulted.
        (service-error
          (& certificate)
          (& references)
          (x509.service-identity-default-limits)
          (x509.NoSupportedPresentedIdentifier))]
      [(x509.CertificateErr _) (test.assert-true false "SAN-absent fixture")]))
  (let
    [certificate : x509.Certificate
      (service-certificate
        (tlv 134 (byte_buf.from-string "https://match.test")))]
    [references : x509.ServiceReferences (service-refs "match.test")]
    (service-error
      (& certificate)
      (& references)
      (x509.service-identity-default-limits)
      (x509.NoSupportedPresentedIdentifier)))
  (let
    [san : byte_buf.ByteBuf (byte_buf.new)]
    [index : i64 0]
    [limits : x509.ServiceIdentityLimits (x509.service-identity-default-limits)]
    [references : x509.ServiceReferences (x509.service-references-new)]
    (set! limits.max-references 64)
    (while (< index 64)
      (match (x509.service-reference-add!
        (&mut references)
        (service-ref "long-mismatch.test")
        limits)
        [(x509.ServiceReferenceAdded) unit]
        [(x509.ServiceReferenceAddErr _)
          (test.assert-true false "reference cap boundary")])
      (set! index (+ index 1)))
    (match (x509.service-reference-add!
      (&mut references)
      (service-ref "extra.test")
      limits)
      [(x509.ServiceReferenceAdded)
        (test.assert-true false "hard reference cap")]
      [(x509.ServiceReferenceAddErr error)
        (test.assert-true
          (= error.kind (x509.ReferenceLimit))
          "hard reference cap failure")])
    (set! index 0)
    (while (< index 1024)
      (set! san (append san (service-dns "long-mismatch.tesu")))
      (set! index (+ index 1)))
    (let
      [certificate : x509.Certificate (service-certificate san)]
      [before : i64 (profile.alloc-total)]
      [result : x509.ServiceIdentityResult
        (x509.service-identity (& certificate) (& references) limits)]
      [after : i64 (profile.alloc-total)]
      (test.assert-i64-eq after before "adversarial mismatch allocates nothing")
      (match result
        [(x509.ServiceIdentityMatch _ _)
          (test.assert-true false "adversarial mismatch")]
        [(x509.ServiceIdentityErr error)
          (test.assert-true
            (= error.kind (x509.IdentityMismatch))
            "adversarial category")])
      (service-error
        (& certificate)
        (& references)
        limits
        (x509.IdentityMismatch))
      (set! limits.max-presented 1023)
      (service-error
        (& certificate)
        (& references)
        limits
        (x509.PresentedLimit))))
  (let
    [error : x509.ServiceIdentityError
      (x509.ServiceIdentityError (x509.IdentityMismatch) 123)]
    (test.assert-owned-string-eq
      (x509.service-identity-error-message error)
      "service identity mismatch"
      "stable non-secret diagnostic")))

(test x509-service-dns (service-dns-tests))

(test x509-service-wildcards (service-wildcard-tests))

(test x509-service-ip (service-ip-tests))

(test x509-service-mixed (service-mixed-tests))

(test x509-service-bounds (service-bound-tests))

(define (main) : i64
  (let
    [epoch : String "700101000000Z"]
    [bad-date : String "20230229000000Z"]
    [empty : byte_buf.ByteBuf (byte_buf.new)]
    (match (time.parse (byte_buf.str-as-bytes (& epoch)) 23 0)
      [(time.TimeOk instant) (test.assert-i64-eq instant.epoch-ms 0 "epoch")]
      [(time.TimeErr _) (test.assert-true false "epoch rejected")])
    (match (time.parse (byte_buf.str-as-bytes (& bad-date)) 24 0)
      [(time.TimeOk _)
        (test.assert-true false "invalid calendar date accepted")]
      [(time.TimeErr error)
        (test.assert-i64-eq error.offset 6 "calendar offset")])
    (match (der.validate (byte_buf.as-bytes (& empty)) (der.default-limits))
      [(der.Valid) (test.assert-true false "empty DER accepted")]
      [(der.Invalid error)
        (test.assert-i64-eq error.offset 0 "empty DER offset")])
    (match (pem.decode-certificates
      (byte_buf.as-bytes (& empty))
      (pem.default-limits))
      [(pem.PemOk _) (test.assert-true false "empty PEM accepted")]
      [(pem.PemErr _) unit])
    (match (x509.parse-der (byte_buf.as-bytes (& empty)) (x509.default-limits))
      [(x509.CertificateOk _)
        (test.assert-true false "empty certificate accepted")]
      [(x509.CertificateErr _) unit])
    (fixture
      (& rsa-hex)
      809
      "e2a7983aef350c5100e9a6b45022384c464023b6b46666ae4cc4cabfad8eb498")
    (fixture
      (& ec-hex)
      603
      "97984bae91f97a15f17f117fd6e2ff2f2284d587828a3786435d692486c82185")
    (fixture
      (& ed-hex)
      551
      "6ed36e2777f3108e28d41990ac27364c6a139b6042a60c8c0b60eccce5b78096")
    (fixture
      (& pss-hex)
      859
      "2a9eea703a50934b911d577d64aa1b76d9e7139f350083169da3bb017d604226")
    (schema-negatives)
    (namespace-exclusions 130)
    (namespace-exclusions 129)
    (namespace-exclusions 134)
    (version-tests)
    (other-names)
    (unsupported-name)
    (der-negatives)
    (pem-tests)
    (time-tests)
    (budget-tests)
    (mutation-corpus)
    (field-negatives)
    (custom-attribute)
    (service-dns-tests)
    (service-wildcard-tests)
    (service-ip-tests)
    (service-mixed-tests)
    (service-bound-tests)
    42))