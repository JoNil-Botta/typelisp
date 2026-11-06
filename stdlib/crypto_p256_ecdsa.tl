;# Strict DER ECDSA-P256-SHA256 verification (FIPS 186-5 section 6.4.2).
;#
;# `verify-sha256` accepts a validated `crypto_p256.P256PublicPoint`, the exact
;# message, and one complete DER signature. It hashes the message once, with
;# no raw-digest overload, signing, or protocol policy. Valid high-S signatures
;# are accepted. Obtain received public keys with `public-point-parse` first.
;#
;# Public inputs only: verification reuses crypto_p256's variable-time scalar
;# and double-scalar arithmetic. No private scalar or ECDH path calls this
;# module. Fixed arrays and borrowed byte views allocate nothing. Stack spills
;# can retain public message/hash/signature intermediates; this module handles
;# no secrets and makes no constant-time or whole-machine erasure claim.
;#
;# Usage: `(import stdlib.crypto_p256_ecdsa)`
(import stdlib.byte_buf)
(import stdlib.crypto_p256 as p256)
(import stdlib.crypto_sha256 as sha)

;: Valid, invalid (including malformed DER/range/infinity), or an operational
;: error. Invalid signatures must never be treated as authenticated messages.
(defenum P256EcdsaVerifyResult
  (P256EcdsaValid)
  (P256EcdsaInvalidSignature)
  (P256EcdsaHashFailure sha.Sha256Error)
  (P256EcdsaCoreFailure p256.P256Error))

;: Internal DER cursor: an unsigned fixed-width value and the next tag offset.
(defstruct EcdsaDerInteger
  (octets (Array u8 32))
  (next i64))

;: Internal INTEGER parsing result; no generic ASN.1 surface.
(defenum EcdsaDerIntegerResult
  (EcdsaDerIntegerOk EcdsaDerInteger)
  (EcdsaDerIntegerInvalid))

;: Parse one positive, nonzero, minimally encoded INTEGER, at most 256 bits.
;: All cursor arithmetic is bounded before a byte is read or copied.
(define (ecdsa-der-integer [der : (& der bytes)] [offset : i64]) : EcdsaDerIntegerResult
  (let
    [length : i64 (byte_buf.bytes-length der)]
    (if (or (< offset 0) (> offset (- length 2)))
      (return (EcdsaDerIntegerInvalid))
      unit)
    (if (!= (byte_buf.bytes-ref der offset) (cast 2 : u8))
      (return (EcdsaDerIntegerInvalid))
      unit)
    (let
      [count : i64 (cast (byte_buf.bytes-ref der (+ offset 1)) : i64)]
      [start : i64 (+ offset 2)]
      (if (or (< count 1) (> count 33) (> count (- length start)))
        (return (EcdsaDerIntegerInvalid))
        unit)
      (let
        [first : u8 (byte_buf.bytes-ref der start)]
        [padding : i64
          (if (= first (cast 0 : u8))
            1
            0)]
        (if (or
          (>= first (cast 128 : u8))
          (and
            (= padding 1)
            (or
              (= count 1)
              (< (byte_buf.bytes-ref der (+ start 1)) (cast 128 : u8))))
          (> (- count padding) 32))
          (return (EcdsaDerIntegerInvalid))
          unit)
        (let
          [width : i64 (- count padding)]
          [octets : (Array u8 32) (make-array u8 32)]
          [index : i64 0]
          (while (< index width)
            (set!
              (array-ref octets (+ (- 32 width) index))
              (byte_buf.bytes-ref der (+ (+ start padding) index)))
            (set! index (+ index 1)))
          (EcdsaDerIntegerOk (EcdsaDerInteger octets (+ start count))))))))

;: Internal verification after the entire DER structure and both scalar ranges
;: have been checked. The only hash operation consumes the exact message.
(define (ecdsa-verify-scalars
  [key : p256.P256PublicPoint]
  [message : (& message bytes)]
  [r : p256.P256Scalar]
  [s : p256.P256Scalar]) : P256EcdsaVerifyResult
  (match (sha.digest message)
    [(Sha256FinalizeErr error) (P256EcdsaHashFailure error)]
    [(Sha256FinalizeOk digest)
      (let
        [octets : (Array u8 32) (sha.digest-bytes (& digest))]
        (match (p256.scalar-from-bytes-reduced (__tl_bytes-view octets 0 32))
          [(ErrP256Scalar error) (P256EcdsaCoreFailure error)]
          [(OkP256Scalar e)
            (match (p256.scalar-invert s)
              [(ErrP256Scalar error) (P256EcdsaCoreFailure error)]
              [(OkP256Scalar w)
                (match (p256.point-to-public
                  (p256.public-double-mul
                    (p256.scalar-mul e w)
                    (p256.scalar-mul r w)
                    (p256.public-point-to-point key)))
                  [(ErrP256PublicPoint _) (P256EcdsaInvalidSignature)]
                  [(OkP256PublicPoint point)
                    (if (p256.scalar-eq? (p256.scalar-from-field point.x) r)
                      (P256EcdsaValid)
                      (P256EcdsaInvalidSignature))])])]))]))

;: Verify the exact message with SHA-256 and a validated P-256 public key.
;: Accept exactly SEQUENCE { INTEGER r, INTEGER s }, with short lengths,
;: canonical positive integers in 1..n-1, and no trailing element or byte.
;: Structural rejection precedes hashing and all scalar/point arithmetic.
(define (verify-sha256
  [key : p256.P256PublicPoint]
  [message : (& message bytes)]
  [signature : (& signature bytes)]) : P256EcdsaVerifyResult
  (let
    [length : i64 (byte_buf.bytes-length signature)]
    (if (or (< length 8) (> length 72))
      (return (P256EcdsaInvalidSignature))
      unit)
    (if (or
      (!= (byte_buf.bytes-ref signature 0) (cast 0x30 : u8))
      (!= (cast (byte_buf.bytes-ref signature 1) : i64) (- length 2)))
      (return (P256EcdsaInvalidSignature))
      unit)
    (match (ecdsa-der-integer signature 2)
      [(EcdsaDerIntegerInvalid) (P256EcdsaInvalidSignature)]
      [(EcdsaDerIntegerOk r)
        (match (ecdsa-der-integer signature r.next)
          [(EcdsaDerIntegerInvalid) (P256EcdsaInvalidSignature)]
          [(EcdsaDerIntegerOk s)
            (if (!= s.next length)
              (P256EcdsaInvalidSignature)
              (match (p256.scalar-from-bytes-nonzero
                (__tl_bytes-view r.octets 0 32))
                [(ErrP256Scalar _) (P256EcdsaInvalidSignature)]
                [(OkP256Scalar r-value)
                  (match (p256.scalar-from-bytes-nonzero
                    (__tl_bytes-view s.octets 0 32))
                    [(ErrP256Scalar _) (P256EcdsaInvalidSignature)]
                    [(OkP256Scalar s-value)
                      (ecdsa-verify-scalars key message r-value s-value)])]))])])))