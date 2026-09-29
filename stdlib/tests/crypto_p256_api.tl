;; P-256 field, scalar, point and SEC1 codec checks (#7665). Expected values
;; were computed independently with exact integer arithmetic and checked in; the
;; ECDSA row is RFC 6979 A.2.5 (P-256, SHA-256, message "sample").
(import stdlib.byte_buf)
(import stdlib.crypto_p256 as p256)
(import stdlib.string)
(import stdlib.test)
(import stdlib.text_buf)

(define (hex-nibble [c : char]) : i64
  (cond
    [(and (>= c '0') (<= c '9')) (- (cast c : i64) (cast '0' : i64))]
    [(and (>= c 'a') (<= c 'f')) (+ 10 (- (cast c : i64) (cast 'a' : i64)))]
    [else -1]))

(define (hex-bytes [hex : String]) : byte_buf.ByteBuf
  (let
    [length : i64 (string.string-length hex)]
    [out : byte_buf.ByteBuf (byte_buf.with-capacity (/ length 2))]
    [index : i64 0]
    (begin
      (while (< index length)
        (let
          [high : i64 (hex-nibble (string.string-ref hex index))]
          [low : i64 (hex-nibble (string.string-ref hex (+ index 1)))]
          (begin
            (test.assert-true
              (and (>= high 0) (>= low 0))
              "P-256 fixture hex digit")
            (set! out (byte_buf.push out (cast (+ (* high 16) low) : u8)))
            (set! index (+ index 2)))))
      out)))

(define (bytes-hex [buf : byte_buf.ByteBuf]) : String
  (let
    [digits : String "0123456789abcdef"]
    [out : text_buf.TextBuf (text_buf.empty)]
    [index : i64 0]
    (begin
      (while (< index (byte_buf.length (& buf)))
        (let
          [byte : i64 (cast (byte_buf.get (& buf) index (cast 0 : u8)) : i64)]
          (begin
            (text_buf.append! out (string.substring (& digits) (/ byte 16) 1))
            (text_buf.append! out (string.substring (& digits) (% byte 16) 1))
            (set! index (+ index 1)))))
      (text_buf.render out))))

(define (kind-code [kind : p256.P256ErrorKind]) : i64
  (match kind
    [(p256.P256InvalidLength) 1]
    [(p256.P256NonCanonical) 2]
    [(p256.P256Zero) 3]
    [(p256.P256InvalidPrefix) 4]
    [(p256.P256NotOnCurve) 5]
    [(p256.P256Infinity) 6]))

(define (field [hex : String]) : p256.P256Field
  (let
    [buf : byte_buf.ByteBuf (hex-bytes hex)]
    (match (p256.field-from-bytes (byte_buf.as-bytes (& buf)))
      [(p256.OkP256Field value) value]
      [(p256.ErrP256Field _)
        (begin
          (test.assert-true false "P-256 field fixture rejected")
          (p256.field-zero))])))

(define (scalar [hex : String]) : p256.P256Scalar
  (let
    [buf : byte_buf.ByteBuf (hex-bytes hex)]
    (match (p256.scalar-from-bytes (byte_buf.as-bytes (& buf)))
      [(p256.OkP256Scalar value) value]
      [(p256.ErrP256Scalar _)
        (begin
          (test.assert-true false "P-256 scalar fixture rejected")
          (p256.scalar-zero))])))

(define (point [hex : String]) : p256.P256Point
  (let
    [buf : byte_buf.ByteBuf (hex-bytes hex)]
    (match (p256.public-point-parse (byte_buf.as-bytes (& buf)))
      [(p256.OkP256PublicPoint value) (p256.public-point-to-point value)]
      [(p256.ErrP256PublicPoint _)
        (begin
          (test.assert-true false "P-256 point fixture rejected")
          (p256.point-identity))])))

(define (expect-field
  [value : p256.P256Field]
  [hex : String]
  [message : String]) : unit
  (test.assert-true
    (string.eq (bytes-hex (p256.field-to-bytes value)) hex)
    message))

(define (expect-scalar
  [value : p256.P256Scalar]
  [hex : String]
  [message : String]) : unit
  (test.assert-true
    (string.eq (bytes-hex (p256.scalar-to-bytes value)) hex)
    message))

;: The SEC1 encoding of a non-identity point.
(define (expect-point
  [value : p256.P256Point]
  [hex : String]
  [message : String]) : unit
  (match (p256.point-to-public value)
    [(p256.OkP256PublicPoint public)
      (test.assert-true
        (string.eq (bytes-hex (p256.public-point-to-bytes public)) hex)
        message)]
    [(p256.ErrP256PublicPoint _) (test.assert-true false message)]))

(define (expect-field-error [hex : String] [kind : i64] [message : String]) : unit
  (let
    [buf : byte_buf.ByteBuf (hex-bytes hex)]
    (match (p256.field-from-bytes (byte_buf.as-bytes (& buf)))
      [(p256.OkP256Field _) (test.assert-true false message)]
      [(p256.ErrP256Field error)
        (test.assert-i64-eq (kind-code error.kind) kind message)])))

(define (expect-scalar-error
  [result : p256.ResultP256Scalar]
  [kind : i64]
  [message : String]) : unit
  (match result
    [(p256.OkP256Scalar _) (test.assert-true false message)]
    [(p256.ErrP256Scalar error)
      (test.assert-i64-eq (kind-code error.kind) kind message)]))

(define (expect-point-error
  [hex : String]
  [kind : i64]
  [offset : i64]
  [message : String]) : unit
  (let
    [buf : byte_buf.ByteBuf (hex-bytes hex)]
    (match (p256.public-point-parse (byte_buf.as-bytes (& buf)))
      [(p256.OkP256PublicPoint _) (test.assert-true false message)]
      [(p256.ErrP256PublicPoint error)
        (begin
          (test.assert-i64-eq
            (kind-code error.kind)
            kind
            (string.copy (& message)))
          (test.assert-i64-eq error.offset offset message))])))

(define (field-tests) : unit
  (let
    [a : p256.P256Field
      (field "48411b1216cdf2be402992361d82d5f9893e62607988edcc12a7ea5f814691d2")]
    [b : p256.P256Field
      (field "6b26356e67fb53504d03b2880a11ea1c2dbcdaf47680e6d3b16ad6ee5a6680b7")]
    [p-minus-1 : p256.P256Field
      (field "ffffffff00000001000000000000000000000000fffffffffffffffffffffffe")]
    [zero : p256.P256Field
      (field "0000000000000000000000000000000000000000000000000000000000000000")]
    [one : p256.P256Field
      (field "0000000000000000000000000000000000000000000000000000000000000001")]
    (begin
      (expect-field
        (p256.field-add a b)
        "b36750807ec9460e8d2d44be2794c015b6fb3d54f009d49fc412c14ddbad1289"
        "field add")
      (expect-field
        (p256.field-sub a b)
        "dd1ae5a2aed29f6ef325dfae1370ebdd5b81876d030806f8613d137126e0111a"
        "field sub")
      (expect-field
        (p256.field-mul a b)
        "2f22126b2eacc85a88ca55ec31959e0968d85aa7a0bdaa2faf25636b4443b1b7"
        "field mul")
      (expect-field
        (p256.field-square a)
        "b32d79857b315c9ffba61786d95cf7877c16d88308a83fbb2c99df9b87868825"
        "field square")
      (expect-field
        (p256.field-negate a)
        "b7bee4ece9320d42bfd66dc9e27d2a0676c19da086771233ed5815a07eb96e2d"
        "field negate")
      (match (p256.field-invert a)
        [(p256.OkP256Field inverse)
          (expect-field
            inverse
            "e735f7483530bbcdf9ca06782f2ca4e34b412c2b26b810ba8a0868e4da69b62b"
            "field invert")]
        [(p256.ErrP256Field _) (test.assert-true false "field invert")])
      ;; Carry and reduction edges.
      (expect-field
        (p256.field-add p-minus-1 p-minus-1)
        "ffffffff00000001000000000000000000000000fffffffffffffffffffffffd"
        "(p-1)+(p-1)")
      (expect-field
        (p256.field-mul p-minus-1 p-minus-1)
        "0000000000000000000000000000000000000000000000000000000000000001"
        "(p-1)^2")
      (expect-field
        (p256.field-sub zero one)
        "ffffffff00000001000000000000000000000000fffffffffffffffffffffffe"
        "0-1")
      (expect-field
        (p256.field-add p-minus-1 one)
        "0000000000000000000000000000000000000000000000000000000000000000"
        "(p-1)+1")
      (test.assert-true (p256.field-zero? (p256.field-negate zero)) "-0")
      (match (p256.field-invert p-minus-1)
        [(p256.OkP256Field inverse)
          (expect-field
            inverse
            "ffffffff00000001000000000000000000000000fffffffffffffffffffffffe"
            "invert p-1")]
        [(p256.ErrP256Field _) (test.assert-true false "invert p-1")])
      (match (p256.field-invert zero)
        [(p256.OkP256Field _) (test.assert-true false "invert 0 must fail")]
        [(p256.ErrP256Field error)
          (test.assert-i64-eq (kind-code error.kind) 3 "invert 0 is P256Zero")])
      ;; Canonical parsing: 0, 1 and p-1 are elements; p and above are not.
      (expect-field-error
        "ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
        2
        "p is not canonical")
      (expect-field-error
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        2
        "2^256-1 is not canonical")
      (expect-field-error "00" 1 "short field element")
      (expect-field-error
        "48411b1216cdf2be402992361d82d5f9893e62607988edcc12a7ea5f814691d200"
        1
        "long field element"))))

(define (scalar-tests) : unit
  (let
    [a : p256.P256Scalar
      (scalar
        "a215eb57e3f19a196650589bf20d79966ee104434b77f2d8cbffc4ff75abc144")]
    [b : p256.P256Scalar
      (scalar
        "7d750e4b0d1a2ceaea1a85c7c1d9d4cb43d25b2c550e6ff6c0571526aa520f23")]
    [n-minus-1 : p256.P256Scalar
      (scalar
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")]
    [n-buf : byte_buf.ByteBuf
      (hex-bytes
        "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551")]
    [max-buf : byte_buf.ByteBuf
      (hex-bytes
        "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff")]
    [zero-buf : byte_buf.ByteBuf
      (hex-bytes
        "0000000000000000000000000000000000000000000000000000000000000000")]
    (begin
      (expect-scalar
        (p256.scalar-mul a b)
        "f88fe83246df1125697106599c2be92f6d2be0f4b68c0f220d9b3733061e49ff"
        "scalar mul")
      (expect-scalar
        (p256.scalar-add a b)
        "1f8af9a3f10bc703506ade63b3e74e61f5cc64c1f96ec44a989d0f63239aab16"
        "scalar add")
      (match (p256.scalar-invert b)
        [(p256.OkP256Scalar inverse)
          (expect-scalar
            inverse
            "28eb6975e2c59d27f49d55d46b00036fd740d30d89024f95c0813beeb693616b"
            "scalar invert")]
        [(p256.ErrP256Scalar _) (test.assert-true false "scalar invert")])
      (expect-scalar
        (p256.scalar-mul n-minus-1 n-minus-1)
        "0000000000000000000000000000000000000000000000000000000000000001"
        "(n-1)^2")
      (expect-scalar-error
        (p256.scalar-from-bytes (byte_buf.as-bytes (& n-buf)))
        2
        "n is not canonical")
      (expect-scalar-error
        (p256.scalar-from-bytes (byte_buf.as-bytes (& max-buf)))
        2
        "2^256-1 is not canonical")
      (expect-scalar-error
        (p256.scalar-from-bytes-nonzero (byte_buf.as-bytes (& zero-buf)))
        3
        "zero is rejected where nonzero is required")
      (expect-scalar-error (p256.scalar-invert (p256.scalar-zero)) 3 "invert 0")
      (match (p256.scalar-from-bytes (byte_buf.as-bytes (& zero-buf)))
        [(p256.OkP256Scalar zero)
          (test.assert-true (p256.scalar-zero? zero) "0 is a scalar")]
        [(p256.ErrP256Scalar _) (test.assert-true false "0 is a scalar")])
      (match (p256.scalar-from-bytes-reduced (byte_buf.as-bytes (& max-buf)))
        [(p256.OkP256Scalar reduced)
          (expect-scalar
            reduced
            "00000000ffffffff00000000000000004319055258e8617b0c46353d039cdaae"
            "2^256-1 mod n")]
        [(p256.ErrP256Scalar _) (test.assert-true false "reduced parse")])
      (match (p256.scalar-from-bytes-reduced (byte_buf.as-bytes (& n-buf)))
        [(p256.OkP256Scalar reduced)
          (test.assert-true (p256.scalar-zero? reduced) "n mod n")]
        [(p256.ErrP256Scalar _) (test.assert-true false "reduced parse of n")])
      (expect-scalar
        (p256.scalar-from-field
          (field
            "ffffffff00000001000000000000000000000000fffffffffffffffffffffffe"))
        "000000000000000000000000000000004319055358e8617b0c46353d039cdaad"
        "(p-1) mod n"))))

(define (point-tests) : unit
  (let
    [g : p256.P256Point (p256.point-generator)]
    [identity : p256.P256Point (p256.point-identity)]
    [g2 : p256.P256Point
      (point
        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1")]
    [neg-g : p256.P256Point
      (point
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a")]
    [q : p256.P256Point
      (point
        "04fa59032e7b1a06e0d40ba1803b93a914699367fd1490fb1b7e9f33af73acc218cb3555a283e64667108d9e434b2e6887fdaf78034a888b136fb5eb837136ba0e")]
    (begin
      (expect-point
        g
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        "generator")
      (expect-point
        (p256.point-double g)
        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
        "double G")
      (expect-point
        (p256.point-add g g)
        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
        "G + G")
      (expect-point
        (p256.point-add g2 g)
        "045ecbe4d1a6330a44c8f7ef951d4bf165e6c6b721efada985fb41661bc6e7fd6c8734640c4998ff7e374b06ce1a64a2ecd82ab036384fb83d9a79b127a27d5032"
        "2G + G")
      (expect-point
        (p256.point-add g identity)
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        "G + O")
      (expect-point
        (p256.point-add identity g)
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        "O + G")
      (expect-point
        (p256.point-negate g)
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a"
        "-G")
      (test.assert-true
        (p256.point-identity? (p256.point-add g neg-g))
        "G + -G")
      (test.assert-true
        (p256.point-identity? (p256.point-double identity))
        "2O")
      (test.assert-true
        (p256.point-identity? (p256.point-add identity identity))
        "O + O")
      (test.assert-true
        (p256.point-eq? (p256.point-double q) (p256.point-add q q))
        "2Q = Q + Q")
      (test.assert-true
        (p256.point-eq? (p256.point-add g q) (p256.point-add q g))
        "commutative")
      (test.assert-true
        (p256.point-eq?
          (p256.point-add (p256.point-add g q) g2)
          (p256.point-add g (p256.point-add q g2)))
        "associative")
      (test.assert-true (not (p256.point-eq? g identity)) "G is not O")
      (match (p256.point-to-public identity)
        [(p256.OkP256PublicPoint _)
          (test.assert-true false "O has no affine form")]
        [(p256.ErrP256PublicPoint error)
          (test.assert-i64-eq (kind-code error.kind) 6 "O is P256Infinity")])
      ;; Public multiplication: 0, 1, 2, n-1, and the generator's order.
      (test.assert-true
        (p256.point-identity? (p256.public-mul (p256.scalar-zero) g))
        "[0]G")
      (expect-point
        (p256.public-mul
          (scalar
            "0000000000000000000000000000000000000000000000000000000000000001")
          g)
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
        "[1]G")
      (expect-point
        (p256.public-mul
          (scalar
            "0000000000000000000000000000000000000000000000000000000000000002")
          g)
        "047cf27b188d034f7e8a52380304b51ac3c08969e277f21b35a60b48fc4766997807775510db8ed040293d9ac69f7430dbba7dade63ce982299e04b79d227873d1"
        "[2]G")
      (expect-point
        (p256.public-mul
          (scalar
            "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
          g)
        "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296b01cbd1c01e58065711814b583f061e9d431cca994cea1313449bf97c840ae0a"
        "[n-1]G")
      (test.assert-true
        (p256.point-identity?
          (p256.point-add
            (p256.public-mul
              (scalar
                "ffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632550")
              g)
            g))
        "[n]G = O")
      (test.assert-true
        (p256.point-identity?
          (p256.public-mul
            (scalar
              "a215eb57e3f19a196650589bf20d79966ee104434b77f2d8cbffc4ff75abc144")
            identity))
        "[k]O")
      (expect-point
        (p256.public-double-mul
          (scalar
            "410a29f5b06143c4ed6c3a1c8113328a07f411b2dd478cff888daf93b24588df")
          (scalar
            "53fbb36e8e0688121c5b4cd2181a74e6cf2ae2cbf9743149a7f415c0a3599996")
          q)
        "044d87f83a79c1e3eb43ab99960896f0fabba2a57f695e8ca4104b52323cede848092ed637b728439e577eb46f09ee8edf8bf9724e170b42026d710d82b48a499f"
        "[u]G + [v]Q")
      (test.assert-true
        (p256.point-identity?
          (p256.public-double-mul (p256.scalar-zero) (p256.scalar-zero) q))
        "[0]G + [0]Q"))))

;: RFC 6979 A.2.5: the published P-256 key and SHA-256 "sample" signature
;: verify through the scalar operations and the double multiplication.
(define (ecdsa-vector-test) : unit
  (let
    [digest-buf : byte_buf.ByteBuf
      (hex-bytes
        "af2bdbe1aa9b6ec1e2ade1d694f41fc71a831d0268e9891562113d8a62add1bf")]
    [r : p256.P256Scalar
      (scalar
        "efd48b2aacb6a8fd1140dd9cd45e81d69d2c877b56aaf991c34d0ea84eaf3716")]
    [s : p256.P256Scalar
      (scalar
        "f7cb1c942d657c41d436c7a1b6e29f65f3e900dbb9aff4064dc4ab2f843acda8")]
    [public : p256.P256Point
      (point
        "0460fed4ba255a9d31c961eb74c6356d68c049b8923b61fa6ce669622e60f29fb67903fe1008b8bc99a41ae9e95628bc64f2f1b20c2d7e9f5177a3c294d4462299")]
    (match (p256.scalar-from-bytes-reduced (byte_buf.as-bytes (& digest-buf)))
      [(p256.ErrP256Scalar _) (test.assert-true false "digest scalar")]
      [(p256.OkP256Scalar e)
        (match (p256.scalar-invert s)
          [(p256.ErrP256Scalar _) (test.assert-true false "s inverse")]
          [(p256.OkP256Scalar w)
            (match (p256.point-to-public
              (p256.public-double-mul
                (p256.scalar-mul e w)
                (p256.scalar-mul r w)
                public))
              [(p256.ErrP256PublicPoint _) (test.assert-true false "R is O")]
              [(p256.OkP256PublicPoint big-r)
                (test.assert-true
                  (p256.scalar-eq? (p256.scalar-from-field big-r.x) r)
                  "RFC 6979 A.2.5 signature verifies")])])])))

(define (codec-tests) : unit
  (begin
    (let
      [g-buf : byte_buf.ByteBuf
        (hex-bytes
          "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")]
      (match (p256.public-point-parse (byte_buf.as-bytes (& g-buf)))
        [(p256.OkP256PublicPoint public)
          (test.assert-true
            (string.eq
              (bytes-hex (p256.public-point-to-bytes public))
              "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5")
            "SEC1 round trip")]
        [(p256.ErrP256PublicPoint _) (test.assert-true false "SEC1 generator")]))
    (expect-point-error "04" 1 1 "short point")
    (expect-point-error "00" 1 1 "infinity encoding")
    (expect-point-error
      "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f500"
      1
      66
      "trailing byte")
    (expect-point-error
      "0248411b1216cdf2be402992361d82d5f9893e62607988edcc12a7ea5f814691d2"
      1
      33
      "compressed length")
    (expect-point-error
      "0348411b1216cdf2be402992361d82d5f9893e62607988edcc12a7ea5f814691d26b26356e67fb53504d03b2880a11ea1c2dbcdaf47680e6d3b16ad6ee5a6680b7"
      4
      0
      "wrong prefix 0x03")
    (expect-point-error
      "04ffffffff00000001000000000000000000000000ffffffffffffffffffffffff4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5"
      2
      1
      "X = p")
    (expect-point-error
      "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296ffffffff00000001000000000000000000000000ffffffffffffffffffffffff"
      2
      33
      "Y = p")
    (expect-point-error
      "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c2964fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f6"
      5
      0
      "off-curve point")))

(define (main) : i64
  (begin
    (field-tests)
    (scalar-tests)
    (point-tests)
    (ecdsa-vector-test)
    (codec-tests)
    42))