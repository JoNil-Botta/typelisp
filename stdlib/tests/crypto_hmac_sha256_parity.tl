;; Pure ABI and target-parity witness. The full RFC/lifecycle corpus uses
;; assertion I/O, which intentionally differs across hosts.
(import stdlib.byte_buf as buf)
(import stdlib.crypto_secret as secret)
(import stdlib.crypto_hmac_sha256 as hmac)

(define (matches?
  [result : hmac.HmacSha256TagResult]
  [expected : (& expected hmac.HmacSha256Tag)]) : bool
  (match result
    [(HmacSha256TagOk tag) (hmac.tag-equal? (& tag) expected)]
    [_ false]))

(define (stream
  [key : (& key secret.SecretBytes)]
  [suffix : (& suffix secret.SecretBytes)]
  [expected : (& expected hmac.HmacSha256Tag)]) : bool
  (match (hmac.new key (hmac.default-limits))
    [(HmacSha256NewErr _) false]
    [(HmacSha256NewOk state)
      (with
        ([active state hmac.close])
        (match (hmac.update!
          (&mut active)
          (buf.str-as-bytes "what do ya want "))
          [(HmacSha256Err _) (return false)]
          [(HmacSha256Ok) unit])
        (match (hmac.update-secret! (&mut active) suffix)
          [(HmacSha256Err _) (return false)]
          [(HmacSha256Ok) unit])
        (matches? (hmac.finalize! (&mut active)) expected))]))

(define (main) : i64
  (let
    [expected : hmac.HmacSha256Tag
      (hmac.HmacSha256Tag
        (array
          91
          220
          193
          70
          191
          96
          117
          78
          106
          4
          36
          38
          8
          149
          117
          199
          90
          0
          63
          8
          157
          39
          57
          131
          157
          236
          88
          185
          100
          236
          56
          67))]
    (match (secret.bytes-from-bytes (buf.str-as-bytes "Jefe") 16)
      [(SecretBytesErr _) 1]
      [(SecretBytesOk key)
        (with
          ([owner key secret.close-bytes])
          (unless
            (matches?
              (hmac.authenticate
                (& owner)
                (buf.str-as-bytes "what do ya want for nothing?")
                (hmac.default-limits))
              (& expected))
            (return 2))
          (match (secret.bytes-from-bytes (buf.str-as-bytes "for nothing?") 32)
            [(SecretBytesErr _) 3]
            [(SecretBytesOk suffix)
              (with
                ([input suffix secret.close-bytes])
                (if (stream (& owner) (& input) (& expected))
                  42
                  4))]))])))