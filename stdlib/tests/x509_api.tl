(import stdlib.asn1_der as der)
(import stdlib.byte_buf)
(import stdlib.crypto_sha256 as sha)
(import stdlib.net.ip)
(import stdlib.pem)
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
(import (vector.vector der.Range core) as ranges)
(import (vector.vector pem.Block core) as blocks)

(include-str rsa-hex "fixtures/x509/rsa.hex.in")
(include-str ec-hex "fixtures/x509/ec.hex.in")
(include-str ed-hex "fixtures/x509/ed.hex.in")
(include-str pss-hex "fixtures/x509/pss.hex.in")
(include-str rsa-pem "fixtures/x509/rsa.pem.in")

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
(define (synthetic [extension : byte_buf.ByteBuf]) : byte_buf.ByteBuf
  (let
    [algorithm : String "300506032b6570"]
    [name : String "300c310a300806035504030c0141"]
    [start : String "500101000000Z"]
    [end : String "491231235959Z"]
    [tbs : byte_buf.ByteBuf (hex "a003020102020101")]
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
    (when
      (> (byte_buf.len extension) 0)
      (set! tbs (append tbs (tlv 163 (tlv 48 extension)))))
    (tlv 48 (append (append (tlv 48 tbs) (hex algorithm)) (tlv 3 (zeros 65))))))

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
  (reject-extension 17 "30058703c00002")
  (reject-extension 17 "30038201ff")
  (reject-extension 17 "30028900")
  (reject-extension 17 "3004a4020500")
  (reject-extension 17 "3004a5020500")
  (reject-extension 30 "3000")
  (reject-extension 30 "3002a000")
  (reject-extension 30 "300ba009300782026162800101")
  (let
    [bytes : byte_buf.ByteBuf
      (synthetic (append (extension 19 true "3000") (extension 19 true "3000")))]
    (expect-rejected (byte_buf.as-bytes (& bytes)))
    unit))

(define (other-names) : unit
  (let
    [bytes : byte_buf.ByteBuf
      (synthetic (extension 17 false "301181016186016188022a03a505a1030c0141"))]
    (match (x509.parse-der (byte_buf.as-bytes (& bytes)) (x509.default-limits))
      [(x509.CertificateErr error)
        (test.assert-i64-eq
          error.offset
          -1
          "supported non-DNS GeneralName rejected")]
      [(x509.CertificateOk certificate)
        (test.assert-i64-eq
          (names.len (& certificate.subject-alt-names))
          4
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
    (other-names)
    (unsupported-name)
    (der-negatives)
    (pem-tests)
    (time-tests)
    (budget-tests)
    (mutation-corpus)
    (field-negatives)
    42))