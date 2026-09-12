(import stdlib.byte_buf)
(import stdlib.crypto_rsa_core as rsa)
(import stdlib.crypto_rsa_verify as verify)
(import stdlib.crypto_sha256 as sha)
(import stdlib.test)

;# Pinned C2SP/Wycheproof testvectors_v1 tcId=1, commit 3fa63dd0344abb611f1fb1d77e119938603ea230.
;# Files: rsa_signature_{2048,3072,4096}_sha256_test.json and
;# rsa_pss_{2048,3072,4096}_sha256_mgf1_32_test.json, plus tcId=1 from
;# rsa_pss_2048_sha256_mgf1_0_test.json as a wrong-salt negative. Moduli
;# below omit Wycheproof's DER-positive sign octet; all messages are empty.
;# Tests do not fetch vectors or use a host crypto provider.
(define (hex-nibble [byte : char]) : i64
  (cond
    [(and (>= byte '0') (<= byte '9')) (- (cast byte : i64) (cast '0' : i64))]
    [(and (>= byte 'a') (<= byte 'f'))
      (+ 10 (- (cast byte : i64) (cast 'a' : i64)))]
    [else -1]))

(define (hex-bytes [hex : String]) : byte_buf.ByteBuf
  (let
    [length : i64 (string-length hex)]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (/ length 2))]
    [index : i64 0]
    (begin
      (test.assert-true (= (% length 2) 0) "RSA fixture hex width")
      (while (< index length)
        (let
          [high : i64 (hex-nibble (string-ref hex index))]
          [low : i64 (hex-nibble (string-ref hex (+ index 1)))]
          (begin
            (test.assert-true
              (and (>= high 0) (>= low 0))
              "RSA fixture hex digit")
            (set! out (byte_buf.push out (cast (+ (* high 16) low) : u8)))
            (set! index (+ index 2)))))
      out)))

(define (bytes-equal? [left : (& left bytes)] [right : (& right bytes)]) : bool
  (let
    [length : i64 (byte_buf.bytes-length left)]
    [index : i64 0]
    [equal : bool (= length (byte_buf.bytes-length right))]
    (begin
      (while (and equal (< index length))
        (begin
          (if (!=
            (byte_buf.bytes-ref left index)
            (byte_buf.bytes-ref right index))
            (set! equal false)
            unit)
          (set! index (+ index 1))))
      equal)))

(define (expect-verified [result : verify.RsaVerifyResult] [message : String]) : unit
  (match result
    [(verify.RsaVerifyOk) unit]
    [(verify.RsaVerifyInvalidSignature) (test.assert-true false message)]
    [(verify.RsaVerifyCoreFailure _) (test.assert-true false message)]
    [(verify.RsaVerifyHashFailure _) (test.assert-true false message)]))

(define (expect-invalid [result : verify.RsaVerifyResult] [message : String]) : unit
  (match result
    [(verify.RsaVerifyInvalidSignature) unit]
    [_ (test.assert-true false message)]))

(define (expect-core-failure
  [result : verify.RsaVerifyResult]
  [message : String]) : unit
  (match result
    [(verify.RsaVerifyCoreFailure _) unit]
    [_ (test.assert-true false message)]))

(define (expect-not-verified
  [result : verify.RsaVerifyResult]
  [message : String]) : unit
  (match result
    [(verify.RsaVerifyOk) (test.assert-true false message)]
    [_ unit]))

(define (mutated [source : (& source bytes)] [index : i64] [change : u8]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.from-bytes source)]
    [view : (&mut out bytes) (byte_buf.as-mut-bytes (&mut out))]
    (begin
      (byte_buf.bytes-set!
        view
        index
        (bit-xor (byte_buf.bytes-ref view index) change))
      out)))

(define (one-below-odd-modulus [source : (& source bytes)]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.from-bytes source)]
    [last : i64 (- (byte_buf.bytes-length source) 1)]
    [view : (&mut out bytes) (byte_buf.as-mut-bytes (&mut out))]
    (begin
      (byte_buf.bytes-set!
        view
        last
        (cast (- (cast (byte_buf.bytes-ref view last) : i64) 1) : u8))
      out)))

(define (expect-pkcs-field-reject
  [encoded : (& encoded bytes)]
  [digest : (& digest sha.Sha256Digest)]
  [index : i64]
  [message : String]) : unit
  (let
    [changed : byte_buf.ByteBuf (mutated encoded index (cast 1 : u8))]
    (test.assert-true
      (not
        (verify.rsa-pkcs1-sha256-encoding-valid?
          (byte_buf.as-bytes (& changed))
          digest))
      message)))

(define (expect-pss-field-reject
  [encoded : (& encoded bytes)]
  [bits : i64]
  [digest : (& digest sha.Sha256Digest)]
  [index : i64]
  [change : u8]
  [message : String]) : unit
  (let
    [changed : byte_buf.ByteBuf (mutated encoded index change)]
    (expect-invalid
      (verify.rsa-pss-sha256-encoding-valid
        (byte_buf.as-bytes (& changed))
        bits
        digest)
      message)))

(define (assert-pkcs-boundaries [digest : (& digest sha.Sha256Digest)]) : unit
  (let
    [minimum : byte_buf.ByteBuf
      (hex-bytes
        "0001ffffffffffffffff003031300d060960864801650304020105000420e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")]
    [too-short : byte_buf.ByteBuf
      (hex-bytes
        "0001ffffffffffffff003031300d060960864801650304020105000420e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")]
    [trailing : byte_buf.ByteBuf
      (byte_buf.push
        (byte_buf.from-bytes (byte_buf.as-bytes (& minimum)))
        (cast 0 : u8))]
    (begin
      (test.assert-true
        (verify.rsa-pkcs1-sha256-encoding-valid?
          (byte_buf.as-bytes (& minimum))
          digest)
        "PKCS eight-FF minimum")
      (test.assert-true
        (not
          (verify.rsa-pkcs1-sha256-encoding-valid?
            (byte_buf.as-bytes (& too-short))
            digest))
        "PKCS seven-FF reject")
      (test.assert-true
        (not
          (verify.rsa-pkcs1-sha256-encoding-valid?
            (byte_buf.as-bytes (& trailing))
            digest))
        "PKCS trailing bytes reject"))))

(define (assert-pkcs-encoding-mutations
  [key : (& key rsa.RsaPublicKey)]
  [signature : (& signature bytes)]
  [message : (& message bytes)]
  [digest : (& digest sha.Sha256Digest)]) : unit
  (match (rsa.public-exponentiate key signature)
    [(rsa.ErrRsaPublicBytes _)
      (test.assert-true false "PKCS fixture exponentiate")]
    [(rsa.OkRsaPublicBytes encoded)
      (let
        [view : (& encoded bytes) (byte_buf.as-bytes (& encoded))]
        [width : i64 (byte_buf.bytes-length view)]
        [short-signature : byte_buf.ByteBuf
          (byte_buf.from-bytes-range signature 1 (- width 1))]
        (begin
          (test.assert-true
            (verify.rsa-pkcs1-sha256-encoding-valid? view digest)
            "PKCS canonical encoded message")
          (expect-pkcs-field-reject view digest 0 "PKCS leading zero")
          (expect-pkcs-field-reject view digest 1 "PKCS block type")
          (expect-pkcs-field-reject view digest 2 "PKCS FF padding")
          (expect-pkcs-field-reject view digest (- width 52) "PKCS delimiter")
          (expect-pkcs-field-reject
            view
            digest
            (- width 51)
            "PKCS DigestInfo tag")
          (expect-pkcs-field-reject
            view
            digest
            (- width 35)
            "PKCS DigestInfo NULL")
          (expect-pkcs-field-reject view digest (- width 1) "PKCS digest")
          (expect-core-failure
            (verify.verify-pkcs1-sha256
              key
              message
              (byte_buf.as-bytes (& short-signature)))
            "PKCS wrong signature width")))]))

(define (assert-pss-encoding-mutations
  [key : (& key rsa.RsaPublicKey)]
  [signature : (& signature bytes)]
  [digest : (& digest sha.Sha256Digest)]) : unit
  (match (rsa.public-exponentiate key signature)
    [(rsa.ErrRsaPublicBytes _)
      (test.assert-true false "PSS fixture exponentiate")]
    [(rsa.OkRsaPublicBytes encoded)
      (let
        [view : (& encoded bytes) (byte_buf.as-bytes (& encoded))]
        [width : i64 (byte_buf.bytes-length view)]
        [bits : i64 (rsa.modulus-bit-length key)]
        [em-length : i64 (/ (+ bits 6) 8)]
        [prefix-length : i64 (- width em-length)]
        [db-length : i64 (- em-length 33)]
        [padding-length : i64 (- db-length 33)]
        (begin
          (expect-verified
            (verify.rsa-pss-sha256-encoding-valid view bits digest)
            "PSS canonical encoded message")
          (expect-invalid
            (verify.rsa-pss-sha256-encoding-valid view (+ bits 1) digest)
            "PSS mismatched modulus width")
          (expect-invalid
            (verify.rsa-pss-sha256-encoding-valid
              view
              9223372036854775807
              digest)
            "PSS untrusted bit length overflow")
          (expect-pss-field-reject
            view
            bits
            digest
            prefix-length
            (cast 0x80 : u8)
            "PSS unused high bit")
          (expect-pss-field-reject
            view
            bits
            digest
            (+ prefix-length 1)
            (cast 1 : u8)
            "PSS DB padding")
          (expect-pss-field-reject
            view
            bits
            digest
            (+ prefix-length padding-length)
            (cast 1 : u8)
            "PSS delimiter")
          (expect-pss-field-reject
            view
            bits
            digest
            (+ (+ prefix-length padding-length) 1)
            (cast 1 : u8)
            "PSS salt")
          (expect-pss-field-reject
            view
            bits
            digest
            (+ prefix-length db-length)
            (cast 1 : u8)
            "PSS H")
          (expect-pss-field-reject
            view
            bits
            digest
            (- width 1)
            (cast 1 : u8)
            "PSS trailer")))]))

(define (assert-mask-bounds [digest : (& digest sha.Sha256Digest)]) : unit
  (begin
    (test.assert-true
      (verify.rsa-mgf1-sha256-domain-valid? 137438953472)
      "MGF1 maximum counter domain")
    (test.assert-true
      (not (verify.rsa-mgf1-sha256-domain-valid? 137438953473))
      "MGF1 counter overflow")
    (match (verify.rsa-mgf1-sha256 digest 0)
      [(verify.RsaMgf1Ok mask)
        (test.assert-i64-eq (byte_buf.length (& mask)) 0 "MGF1 zero length")]
      [_ (test.assert-true false "MGF1 zero rejected")])
    (match (verify.rsa-mgf1-sha256 digest 32)
      [(verify.RsaMgf1Ok mask)
        (let
          [expected : byte_buf.ByteBuf
            (hex-bytes
              "d3bfe98e8f1ce891614854569a20f5f4508d6ab4025b872b7b3a8282ef75b12a")]
          (test.assert-true
            (bytes-equal?
              (byte_buf.as-bytes (& mask))
              (byte_buf.as-bytes (& expected)))
            "MGF1 independently computed first block"))]
      [_ (test.assert-true false "MGF1 digest multiple rejected")])
    (match (verify.rsa-mgf1-sha256 digest 33)
      [(verify.RsaMgf1Ok mask)
        (let
          [expected : byte_buf.ByteBuf
            (hex-bytes
              "d3bfe98e8f1ce891614854569a20f5f4508d6ab4025b872b7b3a8282ef75b12ae3")]
          (test.assert-true
            (bytes-equal?
              (byte_buf.as-bytes (& mask))
              (byte_buf.as-bytes (& expected)))
            "MGF1 independently computed partial block"))]
      [_ (test.assert-true false "MGF1 partial digest rejected")])
    (match (verify.rsa-mgf1-sha256 digest 1025)
      [(verify.RsaMgf1InvalidLength _) unit]
      [_ (test.assert-true false "MGF1 RSA cap")])
    (match (verify.rsa-mgf1-sha256 digest 137438953473)
      [(verify.RsaMgf1InvalidLength _) unit]
      [_ (test.assert-true false "MGF1 domain cap")])))

(define (assert-vector
  [bits : i64]
  [modulus-hex : String]
  [pkcs-hex : String]
  [pss-hex : String]) : unit
  (let
    [modulus : byte_buf.ByteBuf (hex-bytes modulus-hex)]
    [exponent : byte_buf.ByteBuf (hex-bytes "010001")]
    [pkcs : byte_buf.ByteBuf (hex-bytes pkcs-hex)]
    [pss : byte_buf.ByteBuf (hex-bytes pss-hex)]
    [altered-modulus : byte_buf.ByteBuf
      (mutated (byte_buf.as-bytes (& modulus)) 10 (cast 1 : u8))]
    [altered-pkcs : byte_buf.ByteBuf
      (mutated (byte_buf.as-bytes (& pkcs)) 10 (cast 1 : u8))]
    [altered-pss : byte_buf.ByteBuf
      (mutated (byte_buf.as-bytes (& pss)) 10 (cast 1 : u8))]
    [short-pss : byte_buf.ByteBuf
      (byte_buf.from-bytes-range
        (byte_buf.as-bytes (& pss))
        1
        (- (byte_buf.length (& pss)) 1))]
    [empty : String ""]
    [altered : String "altered"]
    (match (rsa.parse-public-key
      (byte_buf.as-bytes (& modulus))
      (byte_buf.as-bytes (& exponent)))
      [(rsa.ErrRsaPublicKey _) (test.assert-true false "Wycheproof key parse")]
      [(rsa.OkRsaPublicKey key)
        (begin
          (test.assert-i64-eq
            (rsa.modulus-bit-length (& key))
            bits
            "Wycheproof key bits")
          (expect-verified
            (verify.verify-pkcs1-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& pkcs)))
            "Wycheproof PKCS#1 valid")
          (expect-verified
            (verify.verify-pss-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& pss)))
            "Wycheproof PSS valid")
          (expect-invalid
            (verify.verify-pkcs1-sha256
              (& key)
              (byte_buf.str-as-bytes (& altered))
              (byte_buf.as-bytes (& pkcs)))
            "PKCS#1 changed message")
          (expect-invalid
            (verify.verify-pss-sha256
              (& key)
              (byte_buf.str-as-bytes (& altered))
              (byte_buf.as-bytes (& pss)))
            "PSS changed message")
          (expect-core-failure
            (verify.verify-pkcs1-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& modulus)))
            "PKCS representative >= modulus")
          (expect-core-failure
            (verify.verify-pss-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& modulus)))
            "PSS representative >= modulus")
          (expect-core-failure
            (verify.verify-pss-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& short-pss)))
            "PSS wrong signature width")
          (expect-not-verified
            (verify.verify-pkcs1-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& altered-pkcs)))
            "PKCS altered signature")
          (expect-not-verified
            (verify.verify-pss-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& altered-pss)))
            "PSS altered signature")
          (match (rsa.parse-public-key
            (byte_buf.as-bytes (& altered-modulus))
            (byte_buf.as-bytes (& exponent)))
            [(rsa.ErrRsaPublicKey _)
              (test.assert-true false "mutated key parse")]
            [(rsa.OkRsaPublicKey other-key)
              (begin
                (expect-not-verified
                  (verify.verify-pkcs1-sha256
                    (& other-key)
                    (byte_buf.str-as-bytes (& empty))
                    (byte_buf.as-bytes (& pkcs)))
                  "PKCS altered key")
                (expect-not-verified
                  (verify.verify-pss-sha256
                    (& other-key)
                    (byte_buf.str-as-bytes (& empty))
                    (byte_buf.as-bytes (& pss)))
                  "PSS altered key"))])
          (match (sha.digest (byte_buf.str-as-bytes (& empty)))
            [(sha.Sha256FinalizeErr _)
              (test.assert-true false "SHA-256 empty message")]
            [(sha.Sha256FinalizeOk digest)
              (begin
                (assert-pkcs-encoding-mutations
                  (& key)
                  (byte_buf.as-bytes (& pkcs))
                  (byte_buf.str-as-bytes (& empty))
                  (& digest))
                (assert-pss-encoding-mutations
                  (& key)
                  (byte_buf.as-bytes (& pss))
                  (& digest))
                (if (= bits 2048)
                  (let
                    [wrong-salt : byte_buf.ByteBuf
                      (hex-bytes
                        "20081f8894a1330c4d503f642880e3c30e398fc6235c24f1be752e2d49cd9493ac0cf999e275c4f89ff08f0d9ba4e264a332525a616d336bd9e822f41ab3f4fae2f48ec66c2e52642ed93b7cb944396fbaa727cbfdfc1f20aace99a6f2a74475c338f8d9f22a38cb5bc51752076503b3aef1e65e5a8f8583d9ae7378ded038cf516898ad06beb90a42b85764526fcea44f74258fa4efb1da253d337f65619181ceb832dfe285ce78ae6b15f204e23bab274e87445d9f5df97f41dc8e3a97736b62591d075744b2552f90bcf1b1393e1e7627ef1f985f2bbabd52e43a35d0ddf4c67126e391f922ef7b1bb1911cd6e1b303cb2910dd70672bbfb62ea4eaad725c")]
                    (begin
                      (assert-mask-bounds (& digest))
                      (assert-pkcs-boundaries (& digest))
                      (expect-invalid
                        (verify.verify-pss-sha256
                          (& key)
                          (byte_buf.str-as-bytes (& empty))
                          (byte_buf.as-bytes (& wrong-salt)))
                        "Wycheproof zero-salt profile rejected")))
                  unit))]))])))

;# Offline synthetic 2049-bit edge fixture: OpenSSL generated 1025/1024-bit
;# public primes; Python 3 built-in pow/hashlib encoded RFC 8017 PSS with
;# SHA-256/MGF1-SHA-256 and salt 00..1f, then signed with e=65537. Only the
;# public modulus, signature, and expected encoded message are checked in.
(define (assert-pss-2049-edge) : unit
  (let
    [modulus : byte_buf.ByteBuf
      (hex-bytes
        "019807f2d361030c77715aafcdda0b4b9e4218f8e5c93edde749e5a5c23bdc01c5c33dd1d1e4be4f447374cdedb0289bed4659876cce4fd44869acf1c32b630737f065155e259f191bc33724facd6971d3d50016e1b7b3bda4099d862c03e4e5d1f6e480f2c046a8cf8dc2dc344c31ea92a61046526494a09be0a571a17b1715421824b19091afb42f3077f7e5774cbaa19baac743af97247f8e1ef35c5939c5b393526d5603e4c0da8d82e8d0078e3e9c7619589329325abf0a64ef0ed060ac112814a5c483b313189f0e4ec4b9afc295605ab8f8c1f091dba2fc20b3a5544f2c1368c271b0bb9235c4a6b9345eafb3fa5106baeab24482355cd9f160464f6efb")]
    [exponent : byte_buf.ByteBuf (hex-bytes "010001")]
    [signature : byte_buf.ByteBuf
      (hex-bytes
        "00996992e5469da931d28fd9a770cb065e47826b55e789017ee642682f8887140fefe486313a0043edc101bd0c9c0d36fa2287fb44ec077cb7593aba4a260b212e5e2624d221ccc519293affc6c4b5dd175ce06dce40b0698a03574b836fd328dfc76acf2f5193ed8b5ce14dfaddfaa7736f101b5c9a0a3ba05c5836c18c14a64235e9e479a2841166d0cebed9fc7f61de9e3abadbf7407214c086e60c12a129156c4ad7c9d857c553852d656de3d4f29616b9f3b1b338c971f29ee15161dcdb0dccaadd375cc48a46bd987465eeba5d26e044322c833cc84459bed75514510f46863e6d6ef32278debb0c6910b19fbc9e721f36f55bd43c367f750cfc64509381")]
    [expected-em : byte_buf.ByteBuf
      (hex-bytes
        "0004996f8ec2ed91f52c654d46f529a035bedcd174115f97779fec40e7b0ee2d833bffa0b7d99586f3f9360dc54b9443840c0df1bf0b9ae6e0129ed42aacf0f507d2680972f0aa984c88a89a2bf4c0fdf244ad10379143b2abf1ca3c02c38a1bd3e9d63e9ef4c2a9ca377a2c7351a24a9855283d69a09c13543cbd08ec687205a58f590c19e649e21567e7cb6d9196418f8a9ca34793595e83a6785102222efd506c314cd2305bb7701b7ff50399e502dd7166104f4280abc105029728ff2e9d7886c40ab3c0e9df3ad695c93c66c9717fa035f77b7210cb39b403b3c1d05e34afb3263c2dcd8d9b94c809e0c2b18d91a097ca509dc32ff5580a3cce0774d72cbc")]
    [empty : String ""]
    (match (rsa.parse-public-key
      (byte_buf.as-bytes (& modulus))
      (byte_buf.as-bytes (& exponent)))
      [(rsa.ErrRsaPublicKey _) (test.assert-true false "2049-bit key parse")]
      [(rsa.OkRsaPublicKey key)
        (begin
          (test.assert-i64-eq
            (rsa.modulus-bit-length (& key))
            2049
            "PSS edge modulus bits")
          (expect-verified
            (verify.verify-pss-sha256
              (& key)
              (byte_buf.str-as-bytes (& empty))
              (byte_buf.as-bytes (& signature)))
            "PSS 2049-bit positive")
          (let
            [high-em-signature : byte_buf.ByteBuf
              (one-below-odd-modulus (byte_buf.as-bytes (& modulus)))]
            (expect-invalid
              (verify.verify-pss-sha256
                (& key)
                (byte_buf.str-as-bytes (& empty))
                (byte_buf.as-bytes (& high-em-signature)))
              "PSS nonzero discarded prefix through public operation"))
          (match (rsa.public-exponentiate
            (& key)
            (byte_buf.as-bytes (& signature)))
            [(rsa.ErrRsaPublicBytes _)
              (test.assert-true false "PSS edge exponentiate")]
            [(rsa.OkRsaPublicBytes encoded)
              (let
                [view : (& encoded bytes) (byte_buf.as-bytes (& encoded))]
                [expected : (& expected-em bytes)
                  (byte_buf.as-bytes (& expected-em))]
                [index : i64 0]
                [equal : bool true]
                (begin
                  (while (< index 257)
                    (begin
                      (if (!=
                        (byte_buf.bytes-ref view index)
                        (byte_buf.bytes-ref expected index))
                        (set! equal false)
                        unit)
                      (set! index (+ index 1))))
                  (test.assert-true
                    equal
                    "PSS independent 2049-bit encoded message")
                  (match (sha.digest (byte_buf.str-as-bytes (& empty)))
                    [(sha.Sha256FinalizeErr _)
                      (test.assert-true false "PSS edge digest")]
                    [(sha.Sha256FinalizeOk digest)
                      (expect-pss-field-reject
                        view
                        2049
                        (& digest)
                        0
                        (cast 1 : u8)
                        "PSS nonzero discarded prefix")])))]))])))

;# 8192-bit capacity coverage: Wycheproof PKCS#1 tcId=1 at the pinned commit,
;# and offline OpenSSL 3.6.3 genpkey/dgst -sha256 -sigopt
;# rsa_padding_mode:pss -sigopt rsa_pss_saltlen:32 over /dev/null for PSS.
(define (assert-8192-scheme
  [modulus-hex : String]
  [signature-hex : String]
  [pss : bool]) : unit
  (let
    [modulus : byte_buf.ByteBuf (hex-bytes modulus-hex)]
    [exponent : byte_buf.ByteBuf (hex-bytes "010001")]
    [signature : byte_buf.ByteBuf (hex-bytes signature-hex)]
    [empty : String ""]
    (match (rsa.parse-public-key
      (byte_buf.as-bytes (& modulus))
      (byte_buf.as-bytes (& exponent)))
      [(rsa.ErrRsaPublicKey _) (test.assert-true false "8192-bit key parse")]
      [(rsa.OkRsaPublicKey key)
        (begin
          (test.assert-i64-eq
            (rsa.modulus-bit-length (& key))
            8192
            "RSA 8192 modulus bits")
          (match (sha.digest (byte_buf.str-as-bytes (& empty)))
            [(sha.Sha256FinalizeErr _)
              (test.assert-true false "8192-bit digest")]
            [(sha.Sha256FinalizeOk digest)
              (if pss
                (begin
                  (expect-verified
                    (verify.verify-pss-sha256
                      (& key)
                      (byte_buf.str-as-bytes (& empty))
                      (byte_buf.as-bytes (& signature)))
                    "PSS 8192-bit positive")
                  (assert-pss-encoding-mutations
                    (& key)
                    (byte_buf.as-bytes (& signature))
                    (& digest)))
                (begin
                  (expect-verified
                    (verify.verify-pkcs1-sha256
                      (& key)
                      (byte_buf.str-as-bytes (& empty))
                      (byte_buf.as-bytes (& signature)))
                    "PKCS 8192-bit positive")
                  (assert-pkcs-encoding-mutations
                    (& key)
                    (byte_buf.as-bytes (& signature))
                    (byte_buf.str-as-bytes (& empty))
                    (& digest))))]))])))

(define (main) : i64
  (begin
    (assert-vector
      2048
      "a2b451a07d0aa5f96e455671513550514a8a5b462ebef717094fa1fee82224e637f9746d3f7cafd31878d80325b6ef5a1700f65903b469429e89d6eac8845097b5ab393189db92512ed8a7711a1253facd20f79c15e8247f3d3e42e46e48c98e254a2fe9765313a03eff8f17e1a029397a1fa26a8dce26f490ed81299615d9814c22da610428e09c7d9658594266f5c021d0fceca08d945a12be82de4d1ece6b4c03145b5d3495d4ed5411eb878daf05fd7afc3e09ada0f1126422f590975a1969816f48698bcbba1b4d9cae79d460d8f9f85e7975005d9bc22c4e5ac0f7c1a45d12569a62807d3b9a02e5a530e773066f453d1f5b4c2e9cf7820283f742b9d5"
      "840f5dac53106dd1f9c57219224cf51289290c42f20466875ba8e830ac5690e541536fcc8ab03b731f82bf66d83f194e7e180b3963ec7a2f3f7904a7ce49aed47da4d4b79421eaf937d301b3e696169297b797c32c076a12be4de0b58e003c5123051a84a10c62f8dac2f42a8640008eb3c7cccd6760ff5b51b689763922582845f048fb8150e5a7a6ca2eccc7bdc85349ad5b26c52137a79fa3fe5c29ab5cd7615013219c1941b6708e9c3c23feff5febaf0c8ebca5750b54e3e6e99a3e876b396f27860b7f3ec4e9191703c6332d944f6f69751167680c79c4f6b57f1cc8755d24b6ec158ccdbacdb23107a33cb6b332516c13274d1f9dccc21dced869e486"
      "4f01e0c12b08625ecac89a69231906edf826380f37c959a96690d046316d68ffce9d5c471694fcebfc6b45534864689256e4fc81c78e583f675d0c94b449647451e81beff01a11a516d5e5ce3f1a910437cb8a3a5096b19fb15f4524a35b23d89cdba12cf5b71aac1047b28c562df7c5542c34ce23a182cf7e0e231934b17294799d44877a1d68ef1b8f073619b7618e6b7c22db20030d98cf591ffc3d4da5f58613ecd5ecfc3b40a1d02f40891ca43695cd4c088b05a8054c89c595a47e274816f35384226f74459ee63e25a1bfc03c360490552ec38343f8ace502f065303b00bc0ec320711b211fde92e57feb9013c3609342495ec0d7cabdec21e54acc38")
    (assert-vector
      3072
      "c6fe23792566023c265287c5ac6f71541c0994d11d059ee6403986efa21c24b51bd91d8862f9df79a4e328e3e27c83df260b25a9b43420affc44b51e8d7525b6f29c372a405104732007527a62ed82fac73f4892a80e09682a41a58cd347017f3be7d801334f92d9321aafd53b51bffabfc752cfccae0b1ee03bdaff9e428cc1c117f1ac96b4fe23f8c23e6381186a66fd59289339ae55c4bcdadbff84abdaa532240d4e1d28b2d0481dadd3b246557ca8fe18092817730b39e6ee378ffcc85b19ffdc916a9b991a6b66d4a9c7bab5f5e7a3722101142e7a4108c15d573b15289e07e46eaea07b42c2abcba330e99554b4656165bb4c0db2b6393a07eca575c51a93c4e15bdb0f747909447e3efe34c67ca8954b530e56a20a1b6d84d45ed1bcd3aa58ec06f184ee5857aaa819e1cca9a26f4e28d6b977d33916db9896d252d1afa762e287cb0d384cc75bfe53f4e922d02dd0a481c042e2d306b4b3c189371e575b25e0005a164cf69dd0976e4d5be476806ea6be6084e71ab4f5ac5c1b1203"
      "157ffb942b1363b5989ec4beb93fb0187ef016de4ce055620825d13c3dafd4fff621c71920e884ba28c5e98b328baac29ad4bfc4d2cae2f0ecb9d1b6c9fbdfc385aa565aaf6c5b3150e085e0316e21d7d440a873074e5d2700d961114ed420478647a4769d832691f7a004d934a89dc249c9343341902d5d0c3d1a623001265634216beacd5f756821f21c3b58111790657690918a2eafa9e85ab1ee44edd3d8bb89e892acf411ba9eaaeef88eca37dffbda72751c117364fd1b38c840d7b42318fcd011a4449aeffc2de32836d3a4f704d4c8ad4e078315d0d1758f098f2ea749ccce62aac592ac4041b5e733ba0431b88332a39a2af7f68f9bb1f469a793b280b964f285ce5cd1ff3adcd7dbd464a7c9414ed45791073f08415be2dd9f01dc2fec8c3a26fe97d9778e2b2fccf71a1ea5e9ce017d2d46778d7e37bb832ebd5825b3257a7852db5cb6c132bcf9ba3522a670b0e866585444ed3601fd32a922818ef6611626eee3ea99cfcfeeaa4c370567cc65e0479bd35e091b772d7445cade"
      "b520065682633ba54c9b713b2ef19cdc1fcf275ba1744c2350da7307a20971cc30eefa37d1667d23d20001a674f0e00df4f9b9e1d5fe7eb85cc45cab5dd625759de83017995c93d48b126df03aa74ef87daea0c1652dd370ad5d663598a383cac217a208b22c7cf0e448cc7ae0555f892ccb8ded6894cfb0c328cb542be0485d860ca77203081f3b04c6f55c5689b1a66b1c24819a4a7ea55f32e00f61accf4b411bb320a96c990173b63ccd74e7da7df5ceaf33a39a8acb89a845a594b164ec6e22cce940eb06f2d487a8bc4574451878c2bbf57d241f76586e0703bf5f86bee832d05b75fabaed6accadfc1ec2cd6e619dbb29b65d6e6f5e118ad52d82a955d21005ecd63fb382f32bb8e2e1e57220b345cd6422bdd84a91495d0ab5775b08139edee960dab1b4ffd9ea5b27398b58e6e35211c3581501e99bf5e3f17fd79381528d28a4927e28082f45bfa9519f98ea663dc84c50317adf0bd5da98b01459011cec61800534dd5afc5a567c19e4a400f06dee74112083b5322615c144ce3b")
    (assert-vector
      4096
      "956353ecb7561945dc5544e4602466078c93f28507701ffd39e2a9813c8ac8740e6ad61c955d484e513b3dcea527e001a018ee2c207c1806a96763280236cd3c820dff79837c9b709cb4b522d3ddbc9192242259c43be75ea244d37ccfa8a4c75024a2cf7cc76e842ea69cc7ca1227405b070047387a5068e4976e4b8ed5f9aadd7b4db024fbb8d7bd8a040d8f6610c1c6eb1d4b606dfd182235d0360880304d5a750603af0c424b8c8e6dbc12c3697d2d609c97547e774e2e362ea96d1690dc9432112c535258b3db2c4c32ad510d6c07ad0788357883869efb8b629298724847925cf42b34386be700f02903db5852276bee2370941f397bdc3905e30964a0b5e73602703340960c3ed6078263b611f197955fecce4b9a32e43cd1d2e5e87c4ceb65edc8853a7ee31d28e16e5adffb8ac7b760fbfc63d5f174f4d0936461dbb12c964a6b6d6cee752e5fca1ab4a9fd238dd3e8860a1d763d2019f9e7b99ed7666d4e038710f90e0093bc566987d6c0092f571376e705b342d066c54e6e2578927b92c1f0928de44e9a6e1f49b907c6aa4f605ec9c398d55df81c67373b03cc8110162fb417f96fd321048647dfcbb392455115cd912ea83351853e6a185284648842adcbd25e67174a3b93b8a64ce2ce9de0e8577b8b662ce32e2565782665dd38e5bb5fcc4fe12e4320dab7773b545a09c6d39d9dbad459f21f3e624ee6ed"
      "368105195f0dc82c2cd37e8edc6ddc0c983dc13ddcf6f9db9a24b52921e5280319a1bcf797f774066d643e5c99b811f0ad9df2a3f430f4848a03ddb97e06daa4d01ddd50bf2b638935cd26b19d6ffccba884a4e7cba35830c6cc5ccce38bc0fcc4ea421347e241711a551c67923b3daaf2e9c51635d416cc2393a9a4f108f84f26990c11dbaacea75e39dc6082b539cd2c0c8dda6c78cbad12e14a352b9dd5c92a3702d8538fcce0e92e26489ea83d75c174ab671210fbc6c397be2167864b519b5136d23a4363ef773ebc140e1da4b0a788d7b1f15a300375ee42b27261675fdfc60c29bab7022dc2e624c7d1f31e278ac089c5880e701bec41f63c8f897c0cecc5eff0a801dbc58d7d4df6e860c20e61f31d9ab2d50e8fbec7471070d8ed06c4c9c725cb63afde0cc4475d3dcb7dcad7eabd874ddf7294cd9d2a66b13b6367a14dfe3827da0c6c8b9e734deece80fd79609ce5ce0a16de6610fd04a09b0b2411bae2bc3222ab4c02867838d0c8346c60589e6204b226efb401841fb95da05ff32989ef935425b943d1b5d2f8af5113491a36c60a98c90b6453144f5fe00a0df3de8d02f0f59c7b94ddc7c8895b1dff8d88f69a9a2cfbb55eda0837800950601fc9e230a5514c9674fb576df8391c51ba0febc29c267462ed5337326b6f40d243ad7d81459ecabbd00126b2142e6ba10d9f903a9918d2280c63ee84b47062e1"
      "492e60b828a9847501c7ff46a4a304ee7bf61ae87dd88cd5598c76289a70ab3afb7fa9efa3228a1e826241c13c2e120d22cd3a38a9b9ec5826a9711bdb119748e0f7080ccf917e8cb53f6f21ed19f4ffad9efd94c66e329226a811eef928816b5edb3b10d1f483b64bcad9b055dc78e99491560f59a598001e76a0bff0ddad4ebfd565495e2b523b02dc80050b64db4a200b5ca9efd8a1339d6cdff6a82dcbf769d3b0ed7ae53ea8f1788eb025e186a5eac02e3e1fb1f0aeec29b2929c7a718c32159609f973109d4a876bcecdeee6c6418df27fa46eb5cd238e274f94ab571c968b2c4a838cd812aa90e4657b95c0ccd68d60bd7d33b6e291a6a13f68e046cd41ecfc2bbe35fa9b4a0c17d89a708f89f975bf5a5eb9abc812b0c498d93d2d161f5c7969afbcf798029f3c14efc3f7c265b93fda572d265e9e116ffa9416e111aad32072f61943e9f0754f6e116ab5119ed09bbe245022b6e8bfe35dcee4a53ed375f5451c43f38f6eb55b48e386030cfb76c408c81f606886c81aacc76a999735682413069cc016f6e390ea2df7e8e74d088fb0643aebf4899ee8177a4a5faea3889181612ffdffcdb3fc699d578eba383e23e1beb68824c0bc7f920afbbea8ce7bf2b7c3bb40f33c6b7c8fb6cf73e6e2f3679669f235ddfebeeafa872918581d99c84d6dc37ff85949449d3994982d332cb9f9b8aca691651c4b63e58f6b38")
    (assert-pss-2049-edge)
    (assert-8192-scheme
      "dced8ed038581210fe2ccadbaa0728450b2bbb2066ca51ad97c2c1e53839dfd9870aa9b82c5029c1864ed48c019e408029b73603c605617be2e823c6f1bee4154ac7900d7bfd7a8c05bbacd4807a0a1855066ebf7f04225a3d7dfd3d16d546746c738a311d0fba6a32f00febf968d619bbe275eac61b80dec34927aef1b29b96ba42967002c33f406bf47209d005b5d2c6d4ffaf63011bf415c3cab548faefbe855754cc885c64e3c74a3f11d1dd2ef3ca88de746cc245cba25c2ab1b6280276265afaedfa24d21ac49e5101290f3a5330e362e6b2897e400839768f67d6adc443e1b51b19403925efa575f030e28668406fa52440ec9965c73fbd89374964058f7acf354decbf6c79d23a7f35d1a296ba0f6ae36117e26ccfb56c453b859a7ba12accb706559c146b245f9d222b5b7c2e158090c0946484c3893365e9bc818a265be8664f53ec6e779b5d73709f082bd943c2fc97731afd44609fc2bd37fab7e92b1715a52aa25115f2af31207aefd497c3bd061eb1a2b0559b9c6b1b2861ad565e9be71091895abb94956f5d862f3a60e0cb9fd37dcb7c218e3a82ebc288edaf3b64c1d8b80e71867b60465c0455d69d3bfadb9b8e4d1241c79f2ea8e6a3b12af6877c1a06b051c8b12b023611a1b0e8e0823632bc16d1698133895df698301f5472b4cbbe4dadbc4fab4617e825d829837f0dc6257dfb370486fe79078145d616a34925d12031e67971e91fcadc302b7a6bea614b7c68d93c54a0692c7ba6080a3522a052fc161b77305e8140d19196c4fd69d35e2cf72438804330411bc8597c52ac834e914156ebaa65ffd71123946d195a0348fe61644e6dd0bc13c89ffb8400832312e0949f7cfa12bf7802d1eda352b34bc3c34edea995548590ad59b249c4674ce1063de9e84cd1d1c4cc9b31def87b39010a1ab344319a630cbbdb74896758138cd8506730f34228798dcba116c01c204353353ceca3ee59491744d04336e5218e6d43361d5c9ac619340599884f82634a64101713c1f2368a7c0ee8d9af80e539caec7cc07545d91c8b03c8aac7556ea169675e5aed7efb71a236710e570b48b7bc922c1b619acd8aecd9c9a991216d67bc324697d8a190c75aa23b5fe032aedae8cb90af0692f061a69346c9b9684cb77209886745d55bde8253bde37821f68364a25e706092962ee1c57adf45af7efc93bc8b5e61524c058968f69e81d901bd63630de3b1856d77878ecf845efde3d0ac3ed39a9570d228c1924c01b72c2b46d0b4c84e0af1f2e9f894a3ad4a0a7845f7f71224d4f14bafdbf4b0b854a70e873a8a1e18ed25eb7e0af22d3e9346174aa03fdf73f5c9a3f7b3526bd42d9fb59734f344aacc910c127d30890279de5e54974805d8870374b47b95bb6bde71ab5c41e9596ec2ec20e588dcd81240452c9614ade0f7c4c35e9e8ca9"
      "621f3710d76cff557ad5e8158c8266d3053e5dadf6054cf3314758285b4524cfd806e75fd55664bf5fa9f9e0ffe50c058a891cc1aaa6f949cfc8ef7d27b6fc046b298fb27b3f9591fa3b5aeb4c15f791ff00ef9e95eca768fb3910cf0c81ef62910df7c47514141a881004d69e58925ea87409d45354ba1ed66cd0eeb927be2e42476f576142bf2b62dc084d015ca9dbb861357beaa94ab3635349c93401116b9f1c73461225371977054b9f2e2591c566b9139d8b96fd57d3e47cde1756309ca18e602a09eb5e1de19c91c9d6de659995e8e611fcc62320fff6ee54ee72583132d1d9f9a44ad19949b372a8ec567fee0fde3463115e3ade7e918b8f490924b3f1bf7a3a218ec64dc3f1d0dcf16c8f4324265a737ec37fa48f10d78fce936a053dd96c69ad3b698ed2a12d4500fb4254933208667c6d187ad70f296830936ba5b7ff2ce6cb6e9479b563d586ba33d32955b881e2b69715ec1a2e8dddbff47b08606a3c0db0b1e58dc7c8e118d16c5ee691babc6605a7f7475162c47c06c93d9b5c4f6a6904ddf7c6cdf45f9958daf87b0d45b629b5b6a7c258d1c7f230d2e34139efe808bbcc8f8eab49fee2b51ce640c124cc115826eecfe3c0409ead85eb08e57b0f451f7a4621b1b7ef3f7f110fb71c57ae1ce1f4de151dc4d6b924de3bf7f39fa5f784b9fc91a0d7c9700711dec27ab9ec0eacc64f826f6f5597f6eaf522b256705bc3591884b0508beb6d80a9849e8156841459ecc96c6e2a1235668078f4d77bad7ff3b727c4442f6605266650bcab399234617f035555e87f08f8846d22720151fc9955390532f3c701bc861d83e00da003f734ddd2b9576712b91140ad9a42097fc47f789bfcd873b34ab8090879d0bc28ccdef234ab34f23f6c574aa019e45b542c4282bd836a2635fbe8261f110dccf9e70980a54c910dfb4da06441900ead072db6e0283393a6c118ee8b0327759519dde55d36b72a920292900a8e68b744d2bd151c734f37a4062708afae1fc23ea0c473d65429810878ff5042f8b9fd98407cd4aa44cad32494355f912c5370d94f3bfe266f899a5fe05010a3f84ab8e6f86206e1936dfeffd4c8d07bf58df9d863d9db032070e228e6a4ba0758e60ef81e5656d3ae82da6c7bc88f7c806e2aedea7a2f9df4f022dba15bcc1a3ec83a267b8d03e4843546d0977adee28cf0ac97fda8420b90c01178bf67c45d4383d5e00f43f70672c867fc73312210dc7ca01bcdbde276c43caaab8f67d6638bfb8dba298d7a81d829ab67e687c443f19e16606334d6abb2712e93a448874697bfe3af41548c96e434a909bd33ec08ecbbbaa319b7ebb3bc33b6be9a52a3f1d10767471a31a1a97f1aff983f8236287eb804b1877bcb6dc2ddfa5d0f55541ab6c13292b4c4af5a24f4382f0605975a5953f8a3696bfe8652b31722aa2a556a"
      false)
    (assert-8192-scheme
      "a82c71124ae9b2a933f0a63ffa0efce61e7bef70adf4ee50b4d7f97c6367c1a3ba85b30a94d6142d9fd6d77a134ded406920e104ba907cc96a7017cbdf9d24c4317fc4b186734ce8572324838ca00a786282b075dd5cf93764c09bf67f67e3c176c66fe9468a49f67c8ef320d8f7b055c7d3aa1786e5cbfe165c5fc30ead4474704b89713ca27114fe61364fabe9423af0a628185aceb7501ab008340378961f949268861ef5c4206af544621f3944eb159733a4aa5085e2ca5c2672fda7edfe7f8d9e0402e538dcdf869bd41f7936375f52c47877a468b0f0834cdf0374d0bdd25d8d873629dbb21ad9479e17dcba14ef9ad2d508b8449c78ed646b5f297fc0aa0861029d8d3c1668a6008c733f8acc1f543e96352082ed55ba92813ee74060fa0e5204f19f925ad1747f18135ca88dba96ca3f1126f1535fb9b6a694248da9d5a5b77957bb1439e21781eef286849938e6c3e5dfdf0e5568fa96d0067b1056e040ac399fe5a3f0a0272e608d78bb038024c173605b67d27fcd1b9e02debcd59ca67963d59cb0dc1bd00217b055095563fd753ea1224f42a89f7b55d1a41e955149403e4ca2d423dab2a87478ab73406ffd27b8d9613db5e778661f8f6df0e58e52744f4599b6c5441055d7c6a62a6effcc4b242bcba33dbc3a92931e04c9d60b8dee12c8ef3d14e02ee55db1793cdc0aa30700354833c79ad79eb5ab73947514b4ec660bcc8a3d62ba9e276cdeeb5d9aefc4d9de4627cd8923f669c0ca2da40994c94649e3b7ac6bf8c2d0c0edabbbe39ec1ec7e63360f4cd812cbd0ca831c921e072a73eef6fe29c09b30c39f4827bdf995bf945b2064cd0eeaa1b883460b10c5538fdf07a2e439df1b23853b2261d2f201e798aa12eb0b5637549f4a33aad04bef44f2e1a72cf2d35511cb7dd6b0353e71c96a39b138f5eb92a0f5f45201eaee01688f0cb643ae9eccb6fd9b5067d5e88fdd891f08214ee01672183d69bed8b60169fce3cf3e974117cb0ab6e98e94a6ae6c9f6b093b7098b0236e502f9ef53673c2954ec80598a4f3155833a3a5a095a63c75585f042990c28210cf331e1814b726828a3183f662f9562a2087b5ed2785000f346dd0b1b5b89b1d6648253d6aced1d6ed7060c381a9f74ce6227a725a21408b8aac9f3d49e8860693784826bbac38f1e5c945ec298f932f7aa400d0c0dedc431550c2857cf933f7f219c6ce2e0471905cee1aa929ed54e875e7df2b561eec33a4f0607159a4be1592f9f778da319827d0eb9172d29d28655d896055a128c1349acff5386c44183fb37a169b2870686c5ced97edfad56ecef31a8c5a961ad185c6ebdbce2cd4a25554d9c437c0f4597c4b9146b2dfe718a96ff7b5a39b1f39b46164684786af2cd342de47ba20cbd0747178fa97bd36c8bdd7ba5bb062cd70865cbe634e5604e5ea61287b"
      "3cefa46940ac784fcde1186a71172352346317d1dea871501741530f713c11e040458cec7276a8079ed426344b20ac73c6fa8232183bc01990f80ae72fce249cc9155c1286ae006e2163b93424a68dc8424affab8c3c08fa51319c48214f82858bf082ff1972813bd9b2a155815ca228687ad35cf5aa0de4f71f1b5df7d35467976232f152f5bbeb811ad86ccf59e5e10b903ad627efd88cb82c0d1c2634d957d5e90b02104a3d0578339687c6f4413a1dcd4cf2aa4c049459ac1f84d57f0cd6ebb892088d42bb86f9803732b70ecc746b9d0812b3cf58c3486f72adaaf46801f5b7e3cdb5156253e0bda60816a72f68ce004f723513af8c5137ed5905bb88fe284dddef550442cc367255f51f748a113db022dec8c8bfcc9a2c44d46e045a2aa46a5c18c3fe6a3881222322fc590bbcfffee27faaeb1ee2e946771527dae3aa17c0ba3cbb3f1a2d227213aa2e56d95c0bacb1723dd4e0de2fc6955bdb46e346a03b4f21519559aeac366fe40ff561df3bc449c26782289e17ddf6c5b94517423d9b59eca84df0ff3938b83f1ddbe72110a25cada04cdd54c3cec9f8589e06176d4897d3cca308fa87c1e2bb284980af5d0b8d8a2c85c6bc000a062c918b6d11dd041453b0d0a028a218fd46e744d86c7f5c02a1071143fbf31fe268c197d9ab1cd46058379e8f3e0d5b1e9a357a8329dd624fcab08d12f547e44950ba4b29acbd9fd8eff123976a324b2e47c92676f73b8a2564aa50c4f621ce93272a7dcf93744ed227788355dcb6747009f5a0b9faafa6bcb158b664ffe93e8dc811c14c5bb062adab43488b8170a3ac0e14f1cc328aaf2237dd6c59c65604aef57dddf72f93092277e4ecb0d52737794845e3008d5c2caae43c37a1c4f38acd1ef8a90ab619cf48269f8018099c83496ca3f332a99a28fac829f007546c7d1186821cd0f6f118c1b5b5fd9a38d8aa896e10eab0f86d1de510b661df279e975fdb393538a8b68bd4f5f0f77de981a8fedf07a7dc2bf28fd1ed8798896f67c28721d8a5ce4b227dc23045939a91547c8f0a7940339c600090de2d0852ff1d90eaf663992ea90d7fcba2ae57447e7629575bd6e8e988df113dc4f2814ad38adc03c6879c014e73a316bc6e75e7a5cf6fdfeb120186b5b5f70d5c3ece799bacce7d69262ed2e5b8db8c3d493f14ad0ae21fdd610d72faf04ae71b1aaa7a06caf25e835923b0f8801016886283de42d9c3ed3c54fe514e64cf4049894ffcf29e2a28a549fd4e8855c8509ca256c7cfea4ca8d5cb5a4e46d559ec53b4ed86bddbad32fe3705e7d03f976cb3a259b82678bb7598a9d8a6baf42dcebfe8793bf7bc610fc713371ef80e252af938d898101db1d677cdf885e5344b92a144ad5777c2ea7380cdb3013db5fcf47f7ad7394963d0b233dc24888d4fbec39d88d0377f488d0d416ca9b855"
      true)
    42))