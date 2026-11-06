(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)
(import stdlib.byte_buf as buf)

;: Retain actual public seal/open production callers, including ABI bridges.
(define (seal
  [key : (& key gcm.GcmKey)]
  [nonce : (& nonce gcm.GcmNonce)]
  [aad : (& aad bytes)]
  [plaintext : (& plaintext bytes)])
  (:export-symbol "gcm_audit_seal") : gcm.GcmSealResult
  (gcm.seal key nonce aad plaintext))

(define (open
  [key : (& key gcm.GcmKey)]
  [nonce : (& nonce gcm.GcmNonce)]
  [aad : (& aad bytes)]
  [ciphertext : (& ciphertext bytes)]
  [tag : (& tag gcm.GcmTag)])
  (:export-symbol "gcm_audit_open") : gcm.GcmOpenResult
  (gcm.open key nonce aad ciphertext tag))

;: Exercise the consuming constructor and both real callers, with a tail.
(define (main) : i64
  (let
    [nonce : gcm.GcmNonce (gcm.GcmNonce (make-array u8 12))]
    [message : String "0123456789abcdefg"]
    [input : (& message bytes) (buf.str-as-bytes (& message))]
    (match (gcm.new (secret.fixed-zero (secret.Secret16)))
      [(GcmKeyOk key)
        (with
          ([owner key gcm.close])
          (match (seal (& owner) (& nonce) input input)
            [(GcmSealOk sealed)
              (match (open
                (& owner)
                (& nonce)
                input
                (buf.as-bytes (& sealed.ciphertext))
                (& sealed.tag))
                [(GcmOpenOk plain)
                  (if (= (buf.len (& plain)) 17)
                    42
                    1)]
                [_ 1])]
            [_ 1]))]
      [_ 1])))