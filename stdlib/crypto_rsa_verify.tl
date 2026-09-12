;# Strict public RSA/SHA-256 signature verification (RFC 8017).
;#
;# This protocol-neutral module accepts checked public keys from
;# `crypto_rsa_core` and exact message bytes. It hashes a message once, then
;# checks the complete PKCS#1 v1.5 or fixed SHA-256/MGF1-SHA-256/32-byte-salt
;# PSS encoding. It has no private-key, signing, ASN.1-policy, or TLS surface.
;# MGF1 and encoded-message helpers are RSA-internal. All operands are public;
;# these operations make no secret constant-time claim.
;#
;# Usage: `(import stdlib.crypto_rsa_verify)`
(import stdlib.byte_buf)
(import stdlib.crypto_rsa_core as rsa)
(import stdlib.crypto_sha256 as sha)

;: Stable verification outcomes. Encoding failures deliberately share one
;: non-secret category; callers must not infer partial acceptance from it.
(defenum RsaVerifyResult
  (RsaVerifyOk)
  (RsaVerifyInvalidSignature)
  (RsaVerifyCoreFailure rsa.RsaCoreError)
  (RsaVerifyHashFailure sha.Sha256Error))

;: Internal bounded MGF1 result.
(defenum RsaMgf1Result
  (RsaMgf1Ok byte_buf.ByteBuf)
  (RsaMgf1InvalidLength i64)
  (RsaMgf1HashFailure sha.Sha256Error))

;: SHA-256 DigestInfo DER prefix with the required explicit NULL.
(define rsa-sha256-digest-info-prefix : (Array u8 19)
  (array
    0x30
    0x31
    0x30
    0x0d
    0x06
    0x09
    0x60
    0x86
    0x48
    0x01
    0x65
    0x03
    0x04
    0x02
    0x01
    0x05
    0x00
    0x04
    0x20))

;: Check the full deterministic EMSA-PKCS1-v1_5-SHA256 encoding.
(define (rsa-pkcs1-sha256-encoding-valid?
  [encoded : (& encoded bytes)]
  [digest : (& digest sha.Sha256Digest)]) : bool
  (let
    [width : i64 (byte_buf.bytes-length encoded)]
    [digest-info-length : i64 51]
    (if (< width (+ digest-info-length 11))
      false
      (let
        [padding-length : i64 (- (- width digest-info-length) 3)]
        [prefix-start : i64 (+ padding-length 3)]
        [index : i64 0]
        [valid : bool
          (and
            (= (byte_buf.bytes-ref encoded 0) (cast 0 : u8))
            (= (byte_buf.bytes-ref encoded 1) (cast 1 : u8))
            (= (byte_buf.bytes-ref encoded (+ padding-length 2)) (cast 0 : u8)))]
        (begin
          (while (< index padding-length)
            (begin
              (if (!= (byte_buf.bytes-ref encoded (+ index 2)) (cast 255 : u8))
                (set! valid false)
                unit)
              (set! index (+ index 1))))
          (set! index 0)
          (while (< index 19)
            (begin
              (if (!=
                (byte_buf.bytes-ref encoded (+ prefix-start index))
                (array-ref rsa-sha256-digest-info-prefix index))
                (set! valid false)
                unit)
              (set! index (+ index 1))))
          (set! index 0)
          (while (< index 32)
            (begin
              (if (!=
                (byte_buf.bytes-ref encoded (+ (+ prefix-start 19) index))
                (sha.digest-byte digest index))
                (set! valid false)
                unit)
              (set! index (+ index 1))))
          valid)))))

;: RFC 8017 MGF1's 2^32-counter domain, before the smaller RSA scratch cap.
(define (rsa-mgf1-sha256-domain-valid? [mask-length : i64]) : bool
  (and (>= mask-length 0) (<= mask-length 137438953472)))

;: Hash seed || I2OSP(counter, 4) and append only the requested prefix.
(define (rsa-mgf1-sha256-with
  [seed : (& seed bytes)]
  [mask-length : i64]
  [counter : u64]
  [out : byte_buf.ByteBuf]) : RsaMgf1Result
  (if (= (byte_buf.length (& out)) mask-length)
    (RsaMgf1Ok out)
    (let
      [input : byte_buf.ByteBuf (byte_buf.with-capacity 36)]
      [index : i64 0]
      (begin
        (while (< index 32)
          (begin
            (set! input (byte_buf.push input (byte_buf.bytes-ref seed index)))
            (set! index (+ index 1))))
        (set!
          input
          (byte_buf.push
            input
            (cast (bit-and (shr counter 24) (cast 255 : u64)) : u8)))
        (set!
          input
          (byte_buf.push
            input
            (cast (bit-and (shr counter 16) (cast 255 : u64)) : u8)))
        (set!
          input
          (byte_buf.push
            input
            (cast (bit-and (shr counter 8) (cast 255 : u64)) : u8)))
        (set!
          input
          (byte_buf.push input (cast (bit-and counter (cast 255 : u64)) : u8)))
        (match (sha.digest (byte_buf.as-bytes (& input)))
          [(sha.Sha256FinalizeErr error) (RsaMgf1HashFailure error)]
          [(sha.Sha256FinalizeOk digest)
            (let
              [next : byte_buf.ByteBuf out]
              [used : i64 0]
              (begin
                (while (and
                  (< used 32)
                  (< (byte_buf.length (& next)) mask-length))
                  (begin
                    (set!
                      next
                      (byte_buf.push next (sha.digest-byte (& digest) used)))
                    (set! used (+ used 1))))
                (rsa-mgf1-sha256-with
                  seed
                  mask-length
                  (+ counter (cast 1 : u64))
                  next)))])))))

;: RSA-internal, fixed-digest MGF1. Reject domain/cap before allocation.
(define (rsa-mgf1-sha256 [seed : (& seed sha.Sha256Digest)] [mask-length : i64]) : RsaMgf1Result
  (if (or
    (not (rsa-mgf1-sha256-domain-valid? mask-length))
    (> mask-length rsa.rsa-maximum-modulus-bytes))
    (RsaMgf1InvalidLength mask-length)
    (let
      [seed-bytes : byte_buf.ByteBuf (byte_buf.with-capacity 32)]
      [index : i64 0]
      (begin
        (while (< index 32)
          (begin
            (set!
              seed-bytes
              (byte_buf.push seed-bytes (sha.digest-byte seed index)))
            (set! index (+ index 1))))
        (rsa-mgf1-sha256-with
          (byte_buf.as-bytes (& seed-bytes))
          mask-length
          (cast 0 : u64)
          (byte_buf.with-capacity mask-length))))))

;: Check the complete fixed-profile EMSA-PSS-SHA256 encoding.
(define (rsa-pss-sha256-encoding-valid
  [encoded : (& encoded bytes)]
  [modulus-bits : i64]
  [message-hash : (& message-hash sha.Sha256Digest)]) : RsaVerifyResult
  (if (or
    (< modulus-bits rsa.rsa-minimum-modulus-bits)
    (> modulus-bits rsa.rsa-maximum-modulus-bits)
    (!= (byte_buf.bytes-length encoded) (/ (+ modulus-bits 7) 8)))
    (RsaVerifyInvalidSignature)
    (let
      [width : i64 (byte_buf.bytes-length encoded)]
      [em-bits : i64 (- modulus-bits 1)]
      [em-length : i64 (/ (+ em-bits 7) 8)]
      [prefix-length : i64 (- width em-length)]
      (if (or (< em-length 66) (< prefix-length 0) (> prefix-length 1))
        (RsaVerifyInvalidSignature)
        (let
          [db-length : i64 (- em-length 33)]
          [unused-bits : i64 (- (* em-length 8) em-bits)]
          [low-mask : u8 (cast (shr (cast 255 : u64) unused-bits) : u8)]
          [h-bytes : (Array u8 32) (init)]
          [index : i64 0]
          [valid : bool true]
          (begin
            (while (< index prefix-length)
              (begin
                (if (!= (byte_buf.bytes-ref encoded index) (cast 0 : u8))
                  (set! valid false)
                  unit)
                (set! index (+ index 1))))
            (if (!= (byte_buf.bytes-ref encoded (- width 1)) (cast 0xbc : u8))
              (set! valid false)
              unit)
            (if (!=
              (bit-and
                (byte_buf.bytes-ref encoded prefix-length)
                (bit-not low-mask))
              (cast 0 : u8))
              (set! valid false)
              unit)
            (set! index 0)
            (while (< index 32)
              (begin
                (set!
                  (array-ref h-bytes index)
                  (byte_buf.bytes-ref
                    encoded
                    (+ (+ prefix-length db-length) index)))
                (set! index (+ index 1))))
            (if (not valid)
              (RsaVerifyInvalidSignature)
              (let
                [h : sha.Sha256Digest (sha.Sha256Digest h-bytes)]
                (match (rsa-mgf1-sha256 (& h) db-length)
                  [(RsaMgf1InvalidLength _) (RsaVerifyInvalidSignature)]
                  [(RsaMgf1HashFailure error) (RsaVerifyHashFailure error)]
                  [(RsaMgf1Ok mask)
                    (let
                      [db : byte_buf.ByteBuf (byte_buf.with-capacity db-length)]
                      [db-index : i64 0]
                      [padding-length : i64 (- db-length 33)]
                      [padding-valid : bool true]
                      (begin
                        (while (< db-index db-length)
                          (let
                            [raw : u8
                              (bit-xor
                                (byte_buf.bytes-ref
                                  encoded
                                  (+ prefix-length db-index))
                                (byte_buf.bytes-ref
                                  (byte_buf.as-bytes (& mask))
                                  db-index))]
                            [selected : u8
                              (if (= db-index 0)
                                (bit-and raw low-mask)
                                raw)]
                            (begin
                              (set! db (byte_buf.push db selected))
                              (if (and
                                (< db-index padding-length)
                                (!= selected (cast 0 : u8)))
                                (set! padding-valid false)
                                unit)
                              (set! db-index (+ db-index 1)))))
                        (if (!=
                          (byte_buf.bytes-ref
                            (byte_buf.as-bytes (& db))
                            padding-length)
                          (cast 1 : u8))
                          (set! padding-valid false)
                          unit)
                        (if (not padding-valid)
                          (RsaVerifyInvalidSignature)
                          (let
                            [m-prime : byte_buf.ByteBuf
                              (byte_buf.with-capacity 72)]
                            [part : i64 0]
                            (begin
                              (while (< part 8)
                                (begin
                                  (set!
                                    m-prime
                                    (byte_buf.push m-prime (cast 0 : u8)))
                                  (set! part (+ part 1))))
                              (set! part 0)
                              (while (< part 32)
                                (begin
                                  (set!
                                    m-prime
                                    (byte_buf.push
                                      m-prime
                                      (sha.digest-byte message-hash part)))
                                  (set! part (+ part 1))))
                              (set! part 0)
                              (while (< part 32)
                                (begin
                                  (set!
                                    m-prime
                                    (byte_buf.push
                                      m-prime
                                      (byte_buf.bytes-ref
                                        (byte_buf.as-bytes (& db))
                                        (+ (+ padding-length 1) part))))
                                  (set! part (+ part 1))))
                              (match (sha.digest
                                (byte_buf.as-bytes (& m-prime)))
                                [(sha.Sha256FinalizeErr error)
                                  (RsaVerifyHashFailure error)]
                                [(sha.Sha256FinalizeOk recomputed)
                                  (if (sha.digest-eq? (& h) (& recomputed))
                                    (RsaVerifyOk)
                                    (RsaVerifyInvalidSignature))]))))))])))))))))

;: Verify an exact message and modulus-width RSASSA-PKCS1-v1_5/SHA-256
;: signature. TLS/X.509/SSH policy admission belongs to their adapters.
(define (verify-pkcs1-sha256
  [key : (& key rsa.RsaPublicKey)]
  [message : (& message bytes)]
  [signature : (& signature bytes)]) : RsaVerifyResult
  (match (rsa.public-exponentiate key signature)
    [(rsa.ErrRsaPublicBytes error) (RsaVerifyCoreFailure error)]
    [(rsa.OkRsaPublicBytes encoded)
      (match (sha.digest message)
        [(sha.Sha256FinalizeErr error) (RsaVerifyHashFailure error)]
        [(sha.Sha256FinalizeOk digest)
          (if (rsa-pkcs1-sha256-encoding-valid?
            (byte_buf.as-bytes (& encoded))
            (& digest))
            (RsaVerifyOk)
            (RsaVerifyInvalidSignature))])]))

;: Verify an exact message and modulus-width RSASSA-PSS/SHA-256 signature
;: with MGF1-SHA-256, 32 salt bytes, and trailer field 1 only.
(define (verify-pss-sha256
  [key : (& key rsa.RsaPublicKey)]
  [message : (& message bytes)]
  [signature : (& signature bytes)]) : RsaVerifyResult
  (match (rsa.public-exponentiate key signature)
    [(rsa.ErrRsaPublicBytes error) (RsaVerifyCoreFailure error)]
    [(rsa.OkRsaPublicBytes encoded)
      (match (sha.digest message)
        [(sha.Sha256FinalizeErr error) (RsaVerifyHashFailure error)]
        [(sha.Sha256FinalizeOk digest)
          (rsa-pss-sha256-encoding-valid
            (byte_buf.as-bytes (& encoded))
            (rsa.modulus-bit-length key)
            (& digest))])]))