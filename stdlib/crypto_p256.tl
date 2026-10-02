;# P-256 (secp256r1) field, scalar, and public point arithmetic.
;#
;# Fixed-width, curve-specific building blocks for TLS P-256 ECDH and ECDSA:
;# arithmetic modulo the field prime `p` and the group order `n`, complete
;# projective point formulas, public-input scalar multiplication, and the
;# strict SEC1 uncompressed public-point codec. It is not a general big-number
;# API, it takes no curve parameters, and it has no secret-scalar path.
;#
;# Representation. A residue is eight little-endian base-2^32 limbs holding its
;# Montgomery form `a * 2^256 mod m`, always fully reduced below `m`. Carries
;# and products use `u64` and depend on no signed overflow, host endianness,
;# allocation or platform provider. Canonical 32-byte big-endian encodings cross
;# the API boundary.
;#
;# Points use homogeneous projective coordinates `(X : Y : Z)` and the complete
;# addition and doubling formulas of Renes, Costello and Batina, "Complete
;# addition formulas for prime order elliptic curves" (EUROCRYPT 2016),
;# Algorithms 4 and 6 for `a = -3`. They have no exceptional inputs: the
;# identity, a point and its inverse, and equal points all take the same steps.
;# The identity is `(0 : 1 : 0)`, distinct from every affine point.
;#
;# Public inputs only. `public-mul` and `public-double-mul` branch on their
;# scalars' bits, and the field and scalar helpers branch on operand values
;# (final subtractions, borrows, comparisons), so everything here takes
;# variable time. That is sound for public data such as ECDSA verification's
;# `u1`, `u2` and a peer's public key. A secret scalar (a private key, ECDH;
;# #7686) needs a fixed-work multiplication of its own and must never reach
;# `public-mul` or `public-double-mul`. It may reuse a helper here only once
;# #7686's fixed-work audit shows that the helper meets its contract.
;#
;# Public points. `public-point-parse` accepts exactly the 65-byte SEC1
;# uncompressed form `0x04 || X || Y` with canonical `X, Y < p` on the curve.
;# P-256 has cofactor 1, so every such point lies in the prime-order subgroup.
;# This partial validation (NIST SP 800-186 D.1.1; SP 800-56A Rev. 3
;# 5.6.2.3.4) is therefore the complete check a received TLS key share needs;
;# computing `[n]Q` adds nothing.
;#
;# Usage: internal TLS/X.509 cryptography modules.
(import stdlib.byte_buf)
(cfg test (import stdlib.test))

;: Why an encoding or operand was rejected.
(defenum P256ErrorKind
  ;; An input has the wrong byte length.
  (P256InvalidLength)
  ;; A canonical element is required and the value is at least the modulus.
  (P256NonCanonical)
  ;; The caller asked for a nonzero value and the input is zero.
  (P256Zero)
  ;; A SEC1 point does not start with the uncompressed prefix 0x04.
  (P256InvalidPrefix)
  ;; The coordinates do not satisfy y^2 = x^3 - 3x + b.
  (P256NotOnCurve)
  ;; The point at infinity where an affine point is required.
  (P256Infinity))

;: A rejection and the input offset or length it concerns.
(defstruct P256Error
  (kind P256ErrorKind)
  (offset i64))

;: An element of GF(p) in Montgomery form.
(defstruct P256Field
  (limbs (Array u32 8)))

;: An element of Z/nZ in Montgomery form.
(defstruct P256Scalar
  (limbs (Array u32 8)))

;: A point in homogeneous projective coordinates; the identity is (0 : 1 : 0).
(defstruct P256Point
  (x P256Field)
  (y P256Field)
  (z P256Field))

;: A validated affine public point: canonical, on the curve, not the identity.
(defstruct P256PublicPoint
  (x P256Field)
  (y P256Field))

;: A parsed or computed field element, or why there is none.
(defenum ResultP256Field
  (OkP256Field P256Field)
  (ErrP256Field P256Error))

;: A parsed or computed scalar, or why there is none.
(defenum ResultP256Scalar
  (OkP256Scalar P256Scalar)
  (ErrP256Scalar P256Error))

;: A validated public point, or why the input is not one.
(defenum ResultP256PublicPoint
  (OkP256PublicPoint P256PublicPoint)
  (ErrP256PublicPoint P256Error))

;: One modulus and its Montgomery parameters.
(defstruct P256Modulus
  (limbs (Array u32 8))
  ;; 2^512 mod m, in normal form.
  (r-squared (Array u32 8))
  ;; -m^-1 mod 2^32.
  (n0 u64))

;: The low 32 bits of a u64: one limb.
(define p256-limb-mask : u64
  0xffffffff)

;: The field prime p = 2^256 - 2^224 + 2^192 + 2^96 - 1 (SP 800-186 3.2.1.3).
(define p256-field-modulus : P256Modulus
  (P256Modulus
    (array
      0xffffffff
      0xffffffff
      0xffffffff
      0x00000000
      0x00000000
      0x00000000
      0x00000001
      0xffffffff)
    (array
      0x00000003
      0x00000000
      0xffffffff
      0xfffffffb
      0xfffffffe
      0xffffffff
      0xfffffffd
      0x00000004)
    (cast 1 : u64)))

;: The group order
;: n = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551.
(define p256-order-modulus : P256Modulus
  (P256Modulus
    (array
      0xfc632551
      0xf3b9cac2
      0xa7179e84
      0xbce6faad
      0xffffffff
      0xffffffff
      0x00000000
      0xffffffff)
    (array
      0xbe79eea2
      0x83244c95
      0x49bd6fa6
      0x4699799c
      0x2b6bec59
      0x2845b239
      0xf3d95620
      0x66e12d94)
    (cast 0xee00bc4f : u64)))

;: 2^256 mod p: the field's one in Montgomery form.
(define p256-field-one-limbs : (Array u32 8)
  (array
    0x00000001
    0x00000000
    0x00000000
    0xffffffff
    0xffffffff
    0xffffffff
    0xfffffffe
    0x00000000))

;: b = 0x5ac635d8aa3a93e7b3ebbd55769886bc651d06b0cc53b0f63bce3c3e27d2604b,
;: in Montgomery form.
(define p256-b-limbs : (Array u32 8)
  (array
    0x29c4bddf
    0xd89cdf62
    0x78843090
    0xacf005cd
    0xf7212ed6
    0xe5a220ab
    0x04874834
    0xdc30061d))

;: The generator's affine coordinates in Montgomery form:
;: Gx = 0x6b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296,
;: Gy = 0x4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5.
(define p256-gx-limbs : (Array u32 8)
  (array
    0x18a9143c
    0x79e730d4
    0x5fedb601
    0x75ba95fc
    0x77622510
    0x79fb732b
    0xa53755c6
    0x18905f76))

;: The generator's y-coordinate in Montgomery form (see Gx).
(define p256-gy-limbs : (Array u32 8)
  (array
    0xce95560a
    0xddf25357
    0xba19e45c
    0x8b4ab8e4
    0xdd21f325
    0xd2e88688
    0x25885d85
    0x8571ff18))

;; --- 256-bit limb arithmetic ------------------------------------------------
;: -1, 0 or 1 as `a` is below, equal to or above `b`.
(define (limbs-compare [a : (Array u32 8)] [b : (Array u32 8)]) : i64
  (let
    [index : i64 7]
    [result : i64 0]
    (begin
      (while (and (>= index 0) (= result 0))
        (begin
          (cond
            [(> (array-ref a index) (array-ref b index)) (set! result 1)]
            [(< (array-ref a index) (array-ref b index)) (set! result -1)]
            [else unit])
          (set! index (- index 1))))
      result)))

;: Whether every limb is zero.
(define (limbs-zero? [a : (Array u32 8)]) : bool
  (let
    [index : i64 0]
    [zero : bool true]
    (begin
      (while (< index 8)
        (begin
          (if (= (array-ref a index) (cast 0 : u32))
            unit
            (set! zero false))
          (set! index (+ index 1))))
      zero)))

;: `a - b mod 2^256`, and whether it borrowed.
(defstruct P256LimbsBorrow
  (limbs (Array u32 8))
  (borrow bool))

;: `a - b mod 2^256` and whether it borrowed.
(define (limbs-sub [a : (Array u32 8)] [b : (Array u32 8)]) : P256LimbsBorrow
  (let
    [out : (Array u32 8) (make-array u32 8)]
    [borrow : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index 8)
        (let
          [minuend : u64 (cast (array-ref a index) : u64)]
          [subtrahend : u64 (+ (cast (array-ref b index) : u64) borrow)]
          (begin
            (if (< minuend subtrahend)
              (begin
                (set!
                  (array-ref out index)
                  (cast (- (+ minuend (+ p256-limb-mask 1)) subtrahend) : u32))
                (set! borrow (cast 1 : u64)))
              (begin
                (set! (array-ref out index) (cast (- minuend subtrahend) : u32))
                (set! borrow (cast 0 : u64))))
            (set! index (+ index 1)))))
      (P256LimbsBorrow out (> borrow (cast 0 : u64))))))

;: `a - b mod 2^256`, dropping the final borrow.
(define (limbs-minus [a : (Array u32 8)] [b : (Array u32 8)]) : (Array u32 8)
  (let
    [difference : P256LimbsBorrow (limbs-sub a b)]
    difference.limbs))

;: `a + b mod 2^256`, dropping the final carry.
(define (limbs-add-wrapping [a : (Array u32 8)] [b : (Array u32 8)]) : (Array
    u32
    8)
  (let
    [out : (Array u32 8) (make-array u32 8)]
    [carry : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index 8)
        (let
          [sum : u64
            (+
              (+
                (cast (array-ref a index) : u64)
                (cast (array-ref b index) : u64))
              carry)]
          (begin
            (set!
              (array-ref out index)
              (cast (bit-and sum p256-limb-mask) : u32))
            (set! carry (shr sum 32))
            (set! index (+ index 1)))))
      out)))

;: `a + b mod m` for `a, b < m`. The sum is below 2m, so one subtraction
;: reduces it; when the 257th bit is set, that subtraction borrows it back.
(define (mod-add
  [a : (Array u32 8)]
  [b : (Array u32 8)]
  [modulus : (& modulus P256Modulus)]) : (Array u32 8)
  (let
    [out : (Array u32 8) (make-array u32 8)]
    [carry : u64 (cast 0 : u64)]
    [index : i64 0]
    (begin
      (while (< index 8)
        (let
          [sum : u64
            (+
              (+
                (cast (array-ref a index) : u64)
                (cast (array-ref b index) : u64))
              carry)]
          (begin
            (set!
              (array-ref out index)
              (cast (bit-and sum p256-limb-mask) : u32))
            (set! carry (shr sum 32))
            (set! index (+ index 1)))))
      (if (or (> carry (cast 0 : u64)) (>= (limbs-compare out modulus.limbs) 0))
        (limbs-minus out modulus.limbs)
        out))))

;: `a - b mod m` for `a, b < m`.
(define (mod-sub
  [a : (Array u32 8)]
  [b : (Array u32 8)]
  [modulus : (& modulus P256Modulus)]) : (Array u32 8)
  (let
    [difference : P256LimbsBorrow (limbs-sub a b)]
    (if difference.borrow
      (limbs-add-wrapping difference.limbs modulus.limbs)
      difference.limbs)))

;: Montgomery product `a * b * 2^-256 mod m` for `a, b < m` (CIOS). Each
;: accumulator word holds one 32-bit limb between steps, so every u64 sum is at
;: most (2^32 - 1)^2 + 2 * (2^32 - 1) = 2^64 - 1. The accumulator stays below
;: 2m, so its ninth word is 0 or 1 and one subtraction reduces it.
(define (mont-mul
  [a : (Array u32 8)]
  [b : (Array u32 8)]
  [modulus : (& modulus P256Modulus)]) : (Array u32 8)
  (let
    [t : (Array u64 10) (make-array u64 10)]
    [outer : i64 0]
    (begin
      (while (< outer 8)
        (let
          [factor : u64 (cast (array-ref b outer) : u64)]
          [carry : u64 (cast 0 : u64)]
          [inner : i64 0]
          (begin
            (while (< inner 8)
              (let
                [sum : u64
                  (+
                    (+
                      (array-ref t inner)
                      (* (cast (array-ref a inner) : u64) factor))
                    carry)]
                (begin
                  (set! (array-ref t inner) (bit-and sum p256-limb-mask))
                  (set! carry (shr sum 32))
                  (set! inner (+ inner 1)))))
            (let
              [top : u64 (+ (array-ref t 8) carry)]
              (begin
                (set! (array-ref t 8) (bit-and top p256-limb-mask))
                (set! (array-ref t 9) (shr top 32))))
            (let
              [q : u64 (bit-and (* (array-ref t 0) modulus.n0) p256-limb-mask)]
              [first : u64
                (+
                  (array-ref t 0)
                  (* q (cast (array-ref modulus.limbs 0) : u64)))]
              [reduce-carry : u64 (shr first 32)]
              [reduce-index : i64 1]
              (begin
                (while (< reduce-index 8)
                  (let
                    [sum : u64
                      (+
                        (+
                          (array-ref t reduce-index)
                          (*
                            q
                            (cast (array-ref modulus.limbs reduce-index) : u64)))
                        reduce-carry)]
                    (begin
                      (set!
                        (array-ref t (- reduce-index 1))
                        (bit-and sum p256-limb-mask))
                      (set! reduce-carry (shr sum 32))
                      (set! reduce-index (+ reduce-index 1)))))
                (let
                  [top : u64 (+ (array-ref t 8) reduce-carry)]
                  (begin
                    (set! (array-ref t 7) (bit-and top p256-limb-mask))
                    (set! (array-ref t 8) (+ (array-ref t 9) (shr top 32)))))))
            (set! outer (+ outer 1)))))
      (let
        [out : (Array u32 8) (make-array u32 8)]
        [index : i64 0]
        (begin
          (while (< index 8)
            (begin
              (set! (array-ref out index) (cast (array-ref t index) : u32))
              (set! index (+ index 1))))
          (if (or
            (> (array-ref t 8) (cast 0 : u64))
            (>= (limbs-compare out modulus.limbs) 0))
            (limbs-minus out modulus.limbs)
            out))))))

;: The normal-form limbs of 1.
(define (limbs-one) : (Array u32 8)
  (let
    [out : (Array u32 8) (make-array u32 8)]
    (begin
      (set! (array-ref out 0) (cast 1 : u32))
      out)))

;: `a * 2^256 mod m` for a normal-form `a < m`.
(define (to-montgomery [a : (Array u32 8)] [modulus : (& modulus P256Modulus)]) : (Array
    u32
    8)
  (mont-mul a modulus.r-squared modulus))

;: The normal form of a Montgomery-form residue.
(define (from-montgomery
  [a : (Array u32 8)]
  [modulus : (& modulus P256Modulus)]) : (Array u32 8)
  (mont-mul a (limbs-one) modulus))

;: `a^(m-2)` in Montgomery form: the inverse of a nonzero `a` modulo a prime.
;: The exponent is the public modulus, so the work is fixed.
(define (mont-invert [a : (Array u32 8)] [modulus : (& modulus P256Modulus)]) : (Array
    u32
    8)
  (let
    [exponent : (Array u32 8)
      (limbs-minus modulus.limbs (limbs-add-wrapping (limbs-one) (limbs-one)))]
    [result : (Array u32 8) (to-montgomery (limbs-one) modulus)]
    [bit : i64 255]
    (begin
      (while (>= bit 0)
        (begin
          (set! result (mont-mul result result modulus))
          (if (=
            (bit-and
              (shr (cast (array-ref exponent (/ bit 32)) : u64) (% bit 32))
              (cast 1 : u64))
            (cast 1 : u64))
            (set! result (mont-mul result a modulus))
            unit)
          (set! bit (- bit 1))))
      result)))

;: The 32 big-endian bytes at `offset` as normal-form limbs.
(define (limbs-from-bytes [bytes : (& bytes bytes)] [offset : i64]) : (Array
    u32
    8)
  (let
    [out : (Array u32 8) (make-array u32 8)]
    [from-end : i64 0]
    (begin
      (while (< from-end 32)
        (let
          [limb-index : i64 (/ from-end 4)]
          [shift : i64 (* (% from-end 4) 8)]
          [byte : u64
            (cast (byte_buf.bytes-ref bytes (- (+ offset 31) from-end)) : u64)]
          (begin
            (set!
              (array-ref out limb-index)
              (cast
                (bit-or
                  (cast (array-ref out limb-index) : u64)
                  (shl byte shift))
                : u32))
            (set! from-end (+ from-end 1)))))
      out)))

;: Append normal-form limbs to `out` as 32 big-endian bytes.
(define (limbs-push-bytes [out : byte_buf.ByteBuf] [a : (Array u32 8)]) : byte_buf.ByteBuf
  (let
    [result : byte_buf.ByteBuf out]
    [index : i64 0]
    (begin
      (while (< index 32)
        (let
          [from-end : i64 (- 31 index)]
          [byte : u64
            (bit-and
              (shr
                (cast (array-ref a (/ from-end 4)) : u64)
                (* (% from-end 4) 8))
              (cast 255 : u64))]
          (begin
            (set! result (byte_buf.push result (cast byte : u8)))
            (set! index (+ index 1)))))
      result)))

;: Parse one canonical element: exactly the 32 bytes at `offset`, below `m`.
(define (canonical-limbs-from-bytes
  [bytes : (& bytes bytes)]
  [offset : i64]
  [modulus : (& modulus P256Modulus)]) : P256LimbsBorrow
  (let
    [value : (Array u32 8) (limbs-from-bytes bytes offset)]
    (P256LimbsBorrow value (>= (limbs-compare value modulus.limbs) 0))))

;: A rejection of `kind` at input offset or length `offset`.
(define (p256-error [kind : P256ErrorKind] [offset : i64]) : P256Error
  (P256Error kind offset))

;; --- the field GF(p) ---------------------------------------------------------
;: The field element 0.
(define (field-zero) : P256Field
  (P256Field (make-array u32 8)))

;: The field element 1.
(define (field-one) : P256Field
  (P256Field p256-field-one-limbs))

;: The canonical big-endian element in exactly `bytes`; 0 is allowed.
(define (field-from-bytes [bytes : (& bytes bytes)]) : ResultP256Field
  (if (not (= (byte_buf.bytes-length bytes) 32))
    (ErrP256Field
      (p256-error (P256InvalidLength) (byte_buf.bytes-length bytes)))
    (field-from-bytes-at bytes 0)))

;: The canonical element in the 32 bytes of `bytes` at `offset`.
(define (field-from-bytes-at [bytes : (& bytes bytes)] [offset : i64]) : ResultP256Field
  (let
    [parsed : P256LimbsBorrow
      (canonical-limbs-from-bytes bytes offset (& p256-field-modulus))]
    (if parsed.borrow
      (ErrP256Field (p256-error (P256NonCanonical) offset))
      (OkP256Field
        (P256Field (to-montgomery parsed.limbs (& p256-field-modulus)))))))

;: The canonical 32-byte big-endian encoding.
(define (field-to-bytes [a : P256Field]) : byte_buf.ByteBuf
  (limbs-push-bytes
    (byte_buf.with-capacity 32)
    (from-montgomery a.limbs (& p256-field-modulus))))

;: `a + b mod p`.
(define (field-add [a : P256Field] [b : P256Field]) : P256Field
  (P256Field (mod-add a.limbs b.limbs (& p256-field-modulus))))

;: `a - b mod p`.
(define (field-sub [a : P256Field] [b : P256Field]) : P256Field
  (P256Field (mod-sub a.limbs b.limbs (& p256-field-modulus))))

;: `-a mod p`.
(define (field-negate [a : P256Field]) : P256Field
  (field-sub (field-zero) a))

;: `a * b mod p`.
(define (field-mul [a : P256Field] [b : P256Field]) : P256Field
  (P256Field (mont-mul a.limbs b.limbs (& p256-field-modulus))))

;: `a^2 mod p`.
(define (field-square [a : P256Field]) : P256Field
  (field-mul a a))

;: The inverse of a nonzero element; zero has none.
(define (field-invert [a : P256Field]) : ResultP256Field
  (if (limbs-zero? a.limbs)
    (ErrP256Field (p256-error (P256Zero) 0))
    (OkP256Field (P256Field (mont-invert a.limbs (& p256-field-modulus))))))

;: Whether two field elements are equal.
(define (field-eq? [a : P256Field] [b : P256Field]) : bool
  (= (limbs-compare a.limbs b.limbs) 0))

;: Whether a field element is 0.
(define (field-zero? [a : P256Field]) : bool
  (limbs-zero? a.limbs))

;; --- the scalars Z/nZ --------------------------------------------------------
;: The scalar 0.
(define (scalar-zero) : P256Scalar
  (P256Scalar (make-array u32 8)))

;: The canonical big-endian scalar in exactly `bytes`, below n; 0 is allowed.
(define (scalar-from-bytes [bytes : (& bytes bytes)]) : ResultP256Scalar
  (if (not (= (byte_buf.bytes-length bytes) 32))
    (ErrP256Scalar
      (p256-error (P256InvalidLength) (byte_buf.bytes-length bytes)))
    (let
      [parsed : P256LimbsBorrow
        (canonical-limbs-from-bytes bytes 0 (& p256-order-modulus))]
      (if parsed.borrow
        (ErrP256Scalar (p256-error (P256NonCanonical) 0))
        (OkP256Scalar
          (P256Scalar (to-montgomery parsed.limbs (& p256-order-modulus))))))))

;: The canonical scalar in [1, n-1], as ECDSA's r and s must be.
(define (scalar-from-bytes-nonzero [bytes : (& bytes bytes)]) : ResultP256Scalar
  (let
    [scalar (try (scalar-from-bytes bytes))]
    (if (limbs-zero? scalar.limbs)
      (ErrP256Scalar (p256-error (P256Zero) 0))
      (OkP256Scalar scalar))))

;: Any 32 big-endian bytes reduced modulo n, as FIPS 186-5 turns a 256-bit
;: digest into `e`. 2^256 < 2n, so one subtraction reduces.
(define (scalar-from-bytes-reduced [bytes : (& bytes bytes)]) : ResultP256Scalar
  (if (not (= (byte_buf.bytes-length bytes) 32))
    (ErrP256Scalar
      (p256-error (P256InvalidLength) (byte_buf.bytes-length bytes)))
    (let
      [parsed : P256LimbsBorrow
        (canonical-limbs-from-bytes bytes 0 (& p256-order-modulus))]
      [reduced : (Array u32 8)
        (if parsed.borrow
          (limbs-minus parsed.limbs p256-order-modulus.limbs)
          parsed.limbs)]
      (OkP256Scalar (P256Scalar (to-montgomery reduced (& p256-order-modulus)))))))

;: A field element's canonical value reduced modulo n, as ECDSA verification
;: compares an x-coordinate with r. p < 2n, so one subtraction reduces.
(define (scalar-from-field [a : P256Field]) : P256Scalar
  (let
    [value : (Array u32 8) (from-montgomery a.limbs (& p256-field-modulus))]
    [reduced : (Array u32 8)
      (if (>= (limbs-compare value p256-order-modulus.limbs) 0)
        (limbs-minus value p256-order-modulus.limbs)
        value)]
    (P256Scalar (to-montgomery reduced (& p256-order-modulus)))))

;: The canonical 32-byte big-endian encoding.
(define (scalar-to-bytes [a : P256Scalar]) : byte_buf.ByteBuf
  (limbs-push-bytes
    (byte_buf.with-capacity 32)
    (from-montgomery a.limbs (& p256-order-modulus))))

;: `a + b mod n`.
(define (scalar-add [a : P256Scalar] [b : P256Scalar]) : P256Scalar
  (P256Scalar (mod-add a.limbs b.limbs (& p256-order-modulus))))

;: `a * b mod n`.
(define (scalar-mul [a : P256Scalar] [b : P256Scalar]) : P256Scalar
  (P256Scalar (mont-mul a.limbs b.limbs (& p256-order-modulus))))

;: The inverse of a nonzero scalar modulo the prime n; zero has none.
(define (scalar-invert [a : P256Scalar]) : ResultP256Scalar
  (if (limbs-zero? a.limbs)
    (ErrP256Scalar (p256-error (P256Zero) 0))
    (OkP256Scalar (P256Scalar (mont-invert a.limbs (& p256-order-modulus))))))

;: Whether two scalars are equal.
(define (scalar-eq? [a : P256Scalar] [b : P256Scalar]) : bool
  (= (limbs-compare a.limbs b.limbs) 0))

;: Whether a scalar is 0.
(define (scalar-zero? [a : P256Scalar]) : bool
  (limbs-zero? a.limbs))

;; --- points ------------------------------------------------------------------
;: The identity (point at infinity), (0 : 1 : 0).
(define (point-identity) : P256Point
  (P256Point (field-zero) (field-one) (field-zero)))

;: The NIST generator G.
(define (point-generator) : P256Point
  (P256Point (P256Field p256-gx-limbs) (P256Field p256-gy-limbs) (field-one)))

;: Whether a point is the identity: its Z is 0.
(define (point-identity? [a : P256Point]) : bool
  (field-zero? a.z))

;: `-P`: (X : -Y : Z).
(define (point-negate [a : P256Point]) : P256Point
  (P256Point a.x (field-negate a.y) a.z))

;: Projective equality: X1 Z2 = X2 Z1 and Y1 Z2 = Y2 Z1.
(define (point-eq? [a : P256Point] [b : P256Point]) : bool
  (and
    (field-eq? (field-mul a.x b.z) (field-mul b.x a.z))
    (field-eq? (field-mul a.y b.z) (field-mul b.y a.z))))

;: `3a mod p`.
(define (field-triple [a : P256Field]) : P256Field
  (field-add (field-add a a) a))

;: Complete addition (RCB 2016, Algorithm 4 for a = -3): correct for every pair
;: of points, the identity, inverses and equal points included.
(define (point-add [p1 : P256Point] [p2 : P256Point]) : P256Point
  (let
    [b : P256Field (P256Field p256-b-limbs)]
    [xx : P256Field (field-mul p1.x p2.x)]
    [yy : P256Field (field-mul p1.y p2.y)]
    [zz : P256Field (field-mul p1.z p2.z)]
    [xy-pairs : P256Field
      (field-sub
        (field-mul (field-add p1.x p1.y) (field-add p2.x p2.y))
        (field-add xx yy))]
    [yz-pairs : P256Field
      (field-sub
        (field-mul (field-add p1.y p1.z) (field-add p2.y p2.z))
        (field-add yy zz))]
    [xz-pairs : P256Field
      (field-sub
        (field-mul (field-add p1.x p1.z) (field-add p2.x p2.z))
        (field-add xx zz))]
    [bzz3 : P256Field (field-triple (field-sub xz-pairs (field-mul b zz)))]
    [yy-minus : P256Field (field-sub yy bzz3)]
    [yy-plus : P256Field (field-add yy bzz3)]
    [zz3 : P256Field (field-triple zz)]
    [bxz3 : P256Field
      (field-triple (field-sub (field-mul b xz-pairs) (field-add zz3 xx)))]
    [xx3-minus-zz3 : P256Field (field-sub (field-triple xx) zz3)]
    (P256Point
      (field-sub (field-mul yy-plus xy-pairs) (field-mul yz-pairs bxz3))
      (field-add (field-mul yy-plus yy-minus) (field-mul xx3-minus-zz3 bxz3))
      (field-add
        (field-mul yy-minus yz-pairs)
        (field-mul xy-pairs xx3-minus-zz3)))))

;: Complete doubling (RCB 2016, Algorithm 6 for a = -3).
(define (point-double [a : P256Point]) : P256Point
  (let
    [b : P256Field (P256Field p256-b-limbs)]
    [xx : P256Field (field-square a.x)]
    [yy : P256Field (field-square a.y)]
    [zz : P256Field (field-square a.z)]
    [xy2 : P256Field (field-add (field-mul a.x a.y) (field-mul a.x a.y))]
    [xz2 : P256Field (field-add (field-mul a.x a.z) (field-mul a.x a.z))]
    [bzz3 : P256Field (field-triple (field-sub (field-mul b zz) xz2))]
    [yy-minus : P256Field (field-sub yy bzz3)]
    [yy-plus : P256Field (field-add yy bzz3)]
    [zz3 : P256Field (field-triple zz)]
    [bxz6 : P256Field
      (field-triple (field-sub (field-mul b xz2) (field-add zz3 xx)))]
    [xx3-minus-zz3 : P256Field (field-sub (field-triple xx) zz3)]
    [yz2 : P256Field (field-add (field-mul a.y a.z) (field-mul a.y a.z))]
    [yz2-yy : P256Field (field-mul yz2 yy)]
    [yz2-yy2 : P256Field (field-add yz2-yy yz2-yy)]
    (P256Point
      (field-sub (field-mul yy-minus xy2) (field-mul bxz6 yz2))
      (field-add (field-mul yy-plus yy-minus) (field-mul xx3-minus-zz3 bxz6))
      (field-add yz2-yy2 yz2-yy2))))

;: The affine form of a point that is not the identity.
(define (point-to-public [a : P256Point]) : ResultP256PublicPoint
  (match (field-invert a.z)
    [(ErrP256Field _) (ErrP256PublicPoint (p256-error (P256Infinity) 0))]
    [(OkP256Field z-inverse)
      (OkP256PublicPoint
        (P256PublicPoint (field-mul a.x z-inverse) (field-mul a.y z-inverse)))]))

;: The projective form (x : y : 1) of a validated public point.
(define (public-point-to-point [a : P256PublicPoint]) : P256Point
  (P256Point a.x a.y (field-one)))

;: Whether (x, y) satisfies y^2 = x^3 - 3x + b.
(define (on-curve? [x : P256Field] [y : P256Field]) : bool
  (field-eq?
    (field-square y)
    (field-add
      (field-sub (field-mul (field-square x) x) (field-triple x))
      (P256Field p256-b-limbs))))

;: Bit `bit` (0 = least significant) of a scalar's canonical value.
(define (limbs-bit [a : (Array u32 8)] [bit : i64]) : bool
  (=
    (bit-and
      (shr (cast (array-ref a (/ bit 32)) : u64) (% bit 32))
      (cast 1 : u64))
    (cast 1 : u64)))

;: `[k]P` for a PUBLIC scalar: variable time, it branches on k's bits.
;: A secret scalar must not reach this function (see the module header).
(define (public-mul [k : P256Scalar] [a : P256Point]) : P256Point
  (let
    [bits : (Array u32 8) (from-montgomery k.limbs (& p256-order-modulus))]
    [result : P256Point (point-identity)]
    [bit : i64 255]
    (begin
      (while (>= bit 0)
        (begin
          (set! result (point-double result))
          (if (limbs-bit bits bit)
            (set! result (point-add result a))
            unit)
          (set! bit (- bit 1))))
      result)))

;: `[u]G + [v]Q` for PUBLIC scalars, as ECDSA verification needs: variable time,
;: one shared doubling chain (Shamir's trick).
(define (public-double-mul [u : P256Scalar] [v : P256Scalar] [q : P256Point]) : P256Point
  (let
    [u-bits : (Array u32 8) (from-montgomery u.limbs (& p256-order-modulus))]
    [v-bits : (Array u32 8) (from-montgomery v.limbs (& p256-order-modulus))]
    [g : P256Point (point-generator)]
    [g-plus-q : P256Point (point-add (point-generator) q)]
    [result : P256Point (point-identity)]
    [bit : i64 255]
    (begin
      (while (>= bit 0)
        (let
          [u-set : bool (limbs-bit u-bits bit)]
          [v-set : bool (limbs-bit v-bits bit)]
          (begin
            (set! result (point-double result))
            (cond
              [(and u-set v-set) (set! result (point-add result g-plus-q))]
              [u-set (set! result (point-add result g))]
              [v-set (set! result (point-add result q))]
              [else unit])
            (set! bit (- bit 1)))))
      result)))

;; --- SEC1 uncompressed public points -----------------------------------------
;: A validated public point from exactly the 65 bytes `0x04 || X || Y`.
(define (public-point-parse [bytes : (& bytes bytes)]) : ResultP256PublicPoint
  (cond
    [(not (= (byte_buf.bytes-length bytes) 65))
      (ErrP256PublicPoint
        (p256-error (P256InvalidLength) (byte_buf.bytes-length bytes)))]
    [(not (= (byte_buf.bytes-ref bytes 0) (cast 4 : u8)))
      (ErrP256PublicPoint (p256-error (P256InvalidPrefix) 0))]
    [else
      (let
        [x (try (field-from-bytes-at bytes 1))]
        [y (try (field-from-bytes-at bytes 33))]
        (if (on-curve? x y)
          (OkP256PublicPoint (P256PublicPoint x y))
          (ErrP256PublicPoint (p256-error (P256NotOnCurve) 0))))]))

;: The 65-byte SEC1 uncompressed encoding `0x04 || X || Y`.
(define (public-point-to-bytes [a : P256PublicPoint]) : byte_buf.ByteBuf
  (limbs-push-bytes
    (limbs-push-bytes
      (byte_buf.push (byte_buf.with-capacity 65) (cast 4 : u8))
      (from-montgomery a.x.limbs (& p256-field-modulus)))
    (from-montgomery a.y.limbs (& p256-field-modulus))))