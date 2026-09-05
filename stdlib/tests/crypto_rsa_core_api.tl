(import stdlib.byte_buf)
(import stdlib.crypto_rsa_core as rsa)
(import stdlib.test)

(define (fail [message : String]) : unit
  (test.assert-true false message))

(define (error-kind-code [kind : rsa.RsaCoreErrorKind]) : i64
  (match kind
    [(rsa.RsaNegativeModulus) 0]
    [(rsa.RsaNegativeExponent) 1]
    [(rsa.RsaInvalidModulusLength) 2]
    [(rsa.RsaNonCanonicalModulus) 3]
    [(rsa.RsaModulusTooSmall) 4]
    [(rsa.RsaModulusTooLarge) 5]
    [(rsa.RsaEvenModulus) 6]
    [(rsa.RsaInvalidExponentLength) 7]
    [(rsa.RsaNonCanonicalExponent) 8]
    [(rsa.RsaExponentTooSmall) 9]
    [(rsa.RsaExponentTooLarge) 10]
    [(rsa.RsaEvenExponent) 11]
    [(rsa.RsaInvalidRepresentativeLength) 12]
    [(rsa.RsaRepresentativeOutOfRange) 13]
    [(rsa.RsaArithmeticInvariant) 14]))

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

;: Deterministic odd public modulus used only by the checked-in fixture set.
(define (fixture-modulus [width : i64] [seed : i64] [high : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity width)]
    [index : i64 0]
    (begin
      (while (< index width)
        (let
          [generated : i64 (% (+ (* index 73) seed) 256)]
          [selected : i64
            (if (= index 0)
              high
              (if (= index (- width 1))
                (bit-or generated 1)
                generated))]
          (begin
            (set! out (byte_buf.push out (cast selected : u8)))
            (set! index (+ index 1)))))
      out)))

;: Deterministic full-width representative strictly below every fixture modulus.
(define (fixture-representative [width : i64] [seed : i64]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity width)]
    [index : i64 0]
    (begin
      (while (< index width)
        (let
          [selected : i64
            (if (= index 0)
              0x12
              (% (+ (+ (* index 29) (* seed 3)) 7) 256))]
          (begin
            (set! out (byte_buf.push out (cast selected : u8)))
            (set! index (+ index 1)))))
      out)))

(define (exponent-65537) : byte_buf.ByteBuf
  (byte_buf.push
    (byte_buf.push
      (byte_buf.push (byte_buf.with-capacity 3) (cast 1 : u8))
      (cast 0 : u8))
    (cast 1 : u8)))

(define (one-byte [value : u8]) : byte_buf.ByteBuf
  (byte_buf.push (byte_buf.with-capacity 1) value))

(define (filled-bytes [length : i64] [value : u8]) : byte_buf.ByteBuf
  (let
    [out : byte_buf.ByteBuf (byte_buf.with-capacity length)]
    [index : i64 0]
    (begin
      (while (< index length)
        (begin
          (set! out (byte_buf.push out value))
          (set! index (+ index 1))))
      out)))

(define (set-buffer-byte!
  [buffer : (&mut buffer byte_buf.ByteBuf)]
  [index : i64]
  [value : u8]) : unit
  (let
    [view : (&mut buffer bytes) (byte_buf.as-mut-bytes buffer)]
    (byte_buf.bytes-set! view index value)))

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

;# Expected values below were generated independently with Python 3's
;# `int.from_bytes`, three-argument `pow`, and `int.to_bytes`; the TypeLisp
;# implementation does not share parsing or arithmetic code with the oracle.
(define (assert-vector
  [width : i64]
  [seed : i64]
  [high : i64]
  [class-bits : i64]
  [expected-retained-bound : i64]
  [expected-hex : String]) : unit
  (let
    [modulus : byte_buf.ByteBuf (fixture-modulus width seed high)]
    [representative : byte_buf.ByteBuf (fixture-representative width seed)]
    [expected : byte_buf.ByteBuf (hex-bytes expected-hex)]
    [exponent : byte_buf.ByteBuf (exponent-65537)]
    (match (rsa.parse-public-key
      (byte_buf.as-bytes (& modulus))
      (byte_buf.as-bytes (& exponent)))
      [(rsa.ErrRsaPublicKey error)
        (test.assert-i64-eq
          (error-kind-code error.kind)
          -1
          "RSA fixture key rejected")]
      [(rsa.OkRsaPublicKey key)
        (begin
          (test.assert-i64-eq
            (rsa.modulus-class-bits (& key))
            class-bits
            "RSA modulus class")
          (test.assert-i64-eq
            (rsa.modulus-bit-length (& key))
            (* width 8)
            "RSA modulus bit length")
          (test.assert-i64-eq
            (rsa.public-exponentiation-multiplication-count (& key))
            22
            "RSA exponentiation multiply schedule")
          (test.assert-i64-eq
            (rsa.public-exponentiation-retained-bytes-upper-bound (& key))
            expected-retained-bound
            "RSA retained allocation bound")
          (match (rsa.public-exponentiate
            (& key)
            (byte_buf.as-bytes (& representative)))
            [(rsa.ErrRsaPublicBytes _)
              (fail "RSA fixture exponentiation failed")]
            [(rsa.OkRsaPublicBytes actual)
              (test.assert-true
                (bytes-equal?
                  (byte_buf.as-bytes (& actual))
                  (byte_buf.as-bytes (& expected)))
                "RSA independent modular exponentiation vector")]))])))

(define (assert-key-error
  [modulus : (& modulus bytes)]
  [modulus-negative : bool]
  [exponent : (& exponent bytes)]
  [exponent-negative : bool]
  [expected-kind : i64]
  [message : String]) : unit
  (match (rsa.parse-public-key-signed
    modulus
    modulus-negative
    exponent
    exponent-negative)
    [(rsa.OkRsaPublicKey _) (fail message)]
    [(rsa.ErrRsaPublicKey error)
      (test.assert-i64-eq (error-kind-code error.kind) expected-kind message)]))

(define (assert-public-result
  [key : (& key rsa.RsaPublicKey)]
  [input : (& input bytes)]
  [expected : (& expected bytes)]
  [message : String]) : unit
  (match (rsa.public-exponentiate key input)
    [(rsa.ErrRsaPublicBytes _) (fail message)]
    [(rsa.OkRsaPublicBytes actual)
      (test.assert-true
        (bytes-equal? (byte_buf.as-bytes (& actual)) expected)
        message)]))

(define (assert-public-error
  [key : (& key rsa.RsaPublicKey)]
  [input : (& input bytes)]
  [expected-kind : i64]
  [message : String]) : unit
  (match (rsa.public-exponentiate key input)
    [(rsa.OkRsaPublicBytes _) (fail message)]
    [(rsa.ErrRsaPublicBytes error)
      (test.assert-i64-eq (error-kind-code error.kind) expected-kind message)]))

(define (assert-key-validation) : unit
  (let
    [valid-modulus : byte_buf.ByteBuf (fixture-modulus 256 1 0xd3)]
    [empty-modulus : byte_buf.ByteBuf (byte_buf.with-capacity 1)]
    [short-modulus : byte_buf.ByteBuf (filled-bytes 255 (cast 0xff : u8))]
    [oversized-modulus : byte_buf.ByteBuf (filled-bytes 1025 (cast 0xff : u8))]
    [leading-zero-modulus : byte_buf.ByteBuf (fixture-modulus 256 1 0)]
    [even-modulus : byte_buf.ByteBuf (fixture-modulus 256 1 0xd3)]
    [valid-exponent : byte_buf.ByteBuf (exponent-65537)]
    [empty-exponent : byte_buf.ByteBuf (byte_buf.with-capacity 1)]
    [one-exponent : byte_buf.ByteBuf (one-byte (cast 1 : u8))]
    [even-exponent : byte_buf.ByteBuf (one-byte (cast 4 : u8))]
    [leading-zero-exponent : byte_buf.ByteBuf
      (byte_buf.push
        (byte_buf.push (byte_buf.with-capacity 2) (cast 0 : u8))
        (cast 3 : u8))]
    [oversized-exponent : byte_buf.ByteBuf (filled-bytes 5 (cast 1 : u8))]
    (begin
      (set-buffer-byte! (&mut even-modulus) 255 (cast 2 : u8))
      (assert-key-error
        (byte_buf.as-bytes (& empty-modulus))
        false
        (byte_buf.as-bytes (& valid-exponent))
        false
        2
        "RSA empty modulus")
      (assert-key-error
        (byte_buf.as-bytes (& short-modulus))
        false
        (byte_buf.as-bytes (& valid-exponent))
        false
        4
        "RSA sub-2048 modulus")
      (assert-key-error
        (byte_buf.as-bytes (& oversized-modulus))
        false
        (byte_buf.as-bytes (& valid-exponent))
        false
        5
        "RSA oversized modulus")
      (assert-key-error
        (byte_buf.as-bytes (& leading-zero-modulus))
        false
        (byte_buf.as-bytes (& valid-exponent))
        false
        3
        "RSA noncanonical modulus")
      (assert-key-error
        (byte_buf.as-bytes (& even-modulus))
        false
        (byte_buf.as-bytes (& valid-exponent))
        false
        6
        "RSA even modulus")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        true
        (byte_buf.as-bytes (& valid-exponent))
        false
        0
        "RSA negative modulus")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        false
        (byte_buf.as-bytes (& empty-exponent))
        false
        7
        "RSA empty exponent")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        false
        (byte_buf.as-bytes (& one-exponent))
        false
        9
        "RSA exponent below three")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        false
        (byte_buf.as-bytes (& even-exponent))
        false
        11
        "RSA even exponent")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        false
        (byte_buf.as-bytes (& leading-zero-exponent))
        false
        8
        "RSA noncanonical exponent")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        false
        (byte_buf.as-bytes (& oversized-exponent))
        false
        10
        "RSA exponent above u32 cap")
      (assert-key-error
        (byte_buf.as-bytes (& valid-modulus))
        false
        (byte_buf.as-bytes (& valid-exponent))
        true
        1
        "RSA negative exponent"))))

(define (assert-class-boundary) : unit
  (let
    [modulus : byte_buf.ByteBuf (filled-bytes 257 (cast 1 : u8))]
    [exponent : byte_buf.ByteBuf (one-byte (cast 3 : u8))]
    (match (rsa.parse-public-key
      (byte_buf.as-bytes (& modulus))
      (byte_buf.as-bytes (& exponent)))
      [(rsa.ErrRsaPublicKey _) (fail "RSA 2049-bit modulus rejected")]
      [(rsa.OkRsaPublicKey key)
        (begin
          (test.assert-i64-eq
            (rsa.modulus-bit-length (& key))
            2049
            "RSA 2049-bit exact width")
          (test.assert-i64-eq
            (rsa.modulus-octet-width (& key))
            257
            "RSA 2049-bit octet width")
          (test.assert-i64-eq
            (rsa.modulus-class-bits (& key))
            3072
            "RSA 2049-bit class"))])))

(define (assert-representative-boundaries) : unit
  (let
    [modulus : byte_buf.ByteBuf (filled-bytes 256 (cast 0xff : u8))]
    [exponent : byte_buf.ByteBuf (one-byte (cast 3 : u8))]
    [zero : byte_buf.ByteBuf (filled-bytes 256 (cast 0 : u8))]
    [one : byte_buf.ByteBuf (filled-bytes 256 (cast 0 : u8))]
    [modulus-minus-one : byte_buf.ByteBuf (filled-bytes 256 (cast 0xff : u8))]
    [short : byte_buf.ByteBuf (filled-bytes 255 (cast 0 : u8))]
    (begin
      (set-buffer-byte! (&mut one) 255 (cast 1 : u8))
      (set-buffer-byte! (&mut modulus-minus-one) 255 (cast 0xfe : u8))
      (match (rsa.parse-public-key
        (byte_buf.as-bytes (& modulus))
        (byte_buf.as-bytes (& exponent)))
        [(rsa.ErrRsaPublicKey _) (fail "RSA maximal-limb modulus rejected")]
        [(rsa.OkRsaPublicKey key)
          (begin
            (test.assert-i64-eq
              (rsa.public-exponentiation-multiplication-count (& key))
              7
              "RSA exponent-three schedule")
            (assert-public-result
              (& key)
              (byte_buf.as-bytes (& zero))
              (byte_buf.as-bytes (& zero))
              "RSA zero representative")
            (assert-public-result
              (& key)
              (byte_buf.as-bytes (& one))
              (byte_buf.as-bytes (& one))
              "RSA one representative")
            (assert-public-result
              (& key)
              (byte_buf.as-bytes (& modulus-minus-one))
              (byte_buf.as-bytes (& modulus-minus-one))
              "RSA n-1 representative and maximal carry chain")
            (assert-public-error
              (& key)
              (byte_buf.as-bytes (& modulus))
              13
              "RSA representative equal to modulus")
            (assert-public-error
              (& key)
              (byte_buf.as-bytes (& short))
              12
              "RSA short representative")
            (set! key.exponent (cast 2 : u64))
            (assert-public-error
              (& key)
              (byte_buf.as-bytes (& one))
              14
              "RSA forged prepared key state"))]))))

(define (assert-2048-vector) : unit
  (assert-vector
    256
    1
    0xd3
    2048
    30368
    "792274eb5581a292089cff01b37bd3b8891ee015bc5bd86a898d20e7de9bdbf05679c2e44f2ce14a3569307972ebd72c11d9cd3083dc974298faf6155ba678cee030a8307a22d7a7e0680234a1b2dd4ac01b208d9a66396a61232ddef5f8d98a30ccad44736bb71795992eaced04e263488f494badafbb99064dca46a2476f7037708bdc8c6fdabdabf6303e757a865154dee7f83d56d8840a0a73b1d5e8ea3e451dda43dc88ca4cf12763648565f8cf3b2bacf8645cbec4e5b0ea20467eccb83e4fa6f88176dbcd13e5b8aec60770d7b50e27d4d15453d79008c25dd80b03bf88dc42f52b35233800b8e8adb784cebd95a8c5e9cfe6eb9b0a734128bcb15c59"))

(define (assert-3072-vector) : unit
  (assert-vector
    384
    2
    0xc7
    3072
    44960
    "3ec3b68e91dc4a48b5e79c0c029b16f7e0449fe02a841d7ba0a069ee7d8046663756d657ec69586d8277fa22e7336c893746ebcf0c17f6239aef4e602c6a4149999ed5ea4ac881cde21d4563d1fed4f298f7ec8e859c360673d6de34a430342baafeac8c09d9df62b0c75eedc5c9a3bc660d1417f73ffba8af6907b02d3191bfeb26a6f5e1069773ca50dcfc5532c74c6aa7e5012afe1064e946a9f1d09d6678e9946416401aa1baeee20f03aad7bb3efb986fec95bc8d44e1f31f4f9843eeaec8336f55f0b5f43f814037131be6aadfaef035532aaf6885c056a96ff62a234c21313641d82065270d53360df624513dad68e10167b15ebbf80a0a29058f3df4f9412e5d9a4b48f7016a6802575dd908a48647c3ee054299ce1665e940352d28e1033ef06ca832974a11f37736669c7f7cbcb94995c297e7c90c972c62e9f4aef5122590293eb497a37d84898e48f91e0dcd765fe4ef81596f8ff31ea9ac2d9c4a5e0d922e0535c96160849f4680bb38e05db7bac7846d226decccecd414366e"))

(define (assert-4096-vector) : unit
  (assert-vector
    512
    3
    0xa5
    4096
    59552
    "346d107e9f995cb98a80a4ac52fe75b1d5e7cf9f1541ffe28e8435079a6fd0263e81fd5f5fb1bc91d5ff43cea7017fec74f167ffb4ae8c2106284212e3a274721ae87dbb618028d338db6831b3856abb3557a76ead6ac9e246318a6aeaa6e638e6a539b4c3f9fe02d7b00990841cf084f13010c85e4764b12c4c79e6e9a37372ed95aa70fe063ab8a7b6df95f7a72ee31aad88e483f24f8c82196cd4feec9c7b1168d4d395cac6e127bfe3ab933ab134a2bc7890428ac4229401539347ad0c757bfe68c810bb86eb48e1bd3f72cc3f060bc09f892fd958713edbb9144bec6442a61915d433ba0304dde64a1c29fb197014cc4804f34e218cfe539d0544a367a6e8333200638570970ffb19e8f13e9c8506d3ceafacc4a61a4f61e3c656ca943c859ee962bf0e49d90f32847d36f0905d31deba5c1c2f6f904a4546c9d0bbb00944b66235f3e78ce95bfce3c3bb905a6144fffeec4468134c1e5ef2966e52e92e0d2acfb3a895ad2660e0c8ebb48fbf2b50d4b4f8cc31a3c31afa39ce0d0e10b70c05eaabe6f38092dfd25a1e0b455623b033b1419f73b2b2d934e71190f88577990edb84ad5a93e8adc74ad50771399ee2328673c249410ab06585d3d57dff9a375f464ac0ba6deabe4c883d413b1b0bd721bf69662995edffdb6a7680ca05b8256e87968d6c38fd7afb46f2017d52b84c3f5cecfcdbded06c45848da7680376"))

(define (assert-8192-vector) : unit
  (assert-vector
    1024
    4
    0x91
    8192
    117920
    "4edef3481c9e06776f0e78fb5302d9ec0a8ed3d8d24cf9928271f3054827728903b62080293594f6fc66511be2a68a16face6603abac4c0512291828839ff85facc07ddd465077bd66fd4e98a09e24adffeba9a486af2e4d0cdeb43bcc68d75b2c1a19009fd42344ef24d82f752cce97235330ef659a9980ffaef5c08fe46b4ac3e487596ddf8495783af869a56e902401d72a840c794cc5736d674985f63825543db66d595e52ccfe8942e00bd3db65cac46d1a66106354bd40b8b1b49b6b5c4493e4f7fecea2487895a8042d34c77db71b70b660179fda94fb7ed3a7b030c630ba6994ca4ad9f9e95c4c7500888d26847e468e9a65dafe284750d115689f996ca7526e18dc05d2ec173070f644e0fc29ab7cdc7b617248851a4d973dd136531045c7640df2dd0abac05ee9cd5a5adac507ee0d51dc4a1eccb330c500538f2877059880fc53d18a6259af07da12e38a52943ce3eaecec0d21761c2ae250cde00b987161087e0fb7a0d11e6782fff409acc1d54e63eb58df34cb49096b09f77956779b3be451d6384a28537de6b0bb0c3f0d5f81f1319cb3d70a62ba995713abba11afaed6851bd2bce9307bebc02e6b0304caadf22da39a65ee32e12cb23c445bca2a335540b4d495a0fbf7d5b991e668ddafab13fc669d4e766008ba12305b7ea13848cfd510a49795956f4b6b341974eb75fa323677a77832dfa81c7d151e7950ba305b623eeacd72221faa36385a6301858e0956a49d14860c11dd677630fdc697918de4ff9ad9a48cd7e398269834fe5218e0eb201787add58ebefed06d32020230e74d4eca7dd13c14ef0c676608136446a374c059d745b7ee054f1bb867e0d41ef203538212bbef389c4e225f0e0bf4819d04693dd742725a54df37f534eab5298d39f424fcb7e56516de3a0029e753d43f0f8f73ef956610dff90c6a661b84220c6a65a21c6bea532f725661822f6ef5a6a5cbeddf8137bab9bab5eb56f2336aba00715fd27850503cfa9877719b22087851977366356447de7e5111a1e2161f684a17dcc43e726337e4d2125283ec9bc8c202a8925e556bdf2f58b5211a94f67580082f6dcef43fe413bb65ad3327ff6c99b011b48f512c180fdba750d17dafc9e4a0338a6edb167cd4df822123ca4d826fdd594ed91e0d8e23813dffb0e77d032f3d04538f9d66c7b43a5449c59652ae5cc8bc15db0b13610a542437fcd6aa37d2b23014d6f812436b67a4c72b8b65e828637ea5010fec83cf4a09670b52e6f03ea3d57275cebce122aa6da6ff4d3dd322a8d394a49629183125f98d0b03978e219fa457103db469f4c39cc13db358d0c81033bbae7e5c4dd36fdfc09f0140cffbaf48ec3af043c545dc1f48fec7a051aafe824fa05b774fe04fa47003bf710d8bbb1df4c52c5576b06875568e4c57c98c7075fde01455e2d9adc9"))

(define (main) : i64
  (begin
    (assert-key-validation)
    (assert-class-boundary)
    (assert-representative-boundaries)
    (assert-2048-vector)
    (assert-3072-vector)
    (assert-4096-vector)
    (assert-8192-vector)
    42))