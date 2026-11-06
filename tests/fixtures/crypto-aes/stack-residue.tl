(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)
(import stdlib.byte_buf as buf)
(import stdlib.test)

;: Public probe phase; the assembly harness uses it to isolate every boundary.
(define probe-phase : i64
  0)

;: Actual typed setup roots retain both variants under both target ABIs.
(define (setup-128 [key : secret.SecretFixed])
  (:export-symbol "scrub_aes128_setup") : aes.Aes128Result
  (aes.new-128 key))

;: Independent AES-256 construction uses the same shared reclaim mechanism.
(define (setup-256 [key : secret.SecretFixed])
  (:export-symbol "scrub_aes256_setup") : aes.Aes256Result
  (aes.new-256 key))

;: Both public block variants must visit the retained block scrub.
(define (blocks) : unit
  (with
    ([source (secret.fixed-zero (secret.Secret16)) secret.close-fixed]
      [destination (secret.fixed-zero (secret.Secret16)) secret.close-fixed])
    (set! probe-phase 1)
    (match (setup-128 (secret.fixed-zero (secret.Secret16)))
      [(Aes128Ok schedule)
        (with
          ([live schedule aes.close-128])
          (set! probe-phase 2)
          (match (aes.encrypt-128! (& live) (& source) (&mut destination))
            [(AesOk) unit]
            [_ (test.assert-true false "AES-128 residue probe")]))]
      [_ (test.assert-true false "AES-128 setup residue probe")])
    (set! probe-phase 3)
    (match (setup-256 (secret.fixed-zero (secret.Secret32)))
      [(Aes256Ok schedule)
        (with
          ([live schedule aes.close-256])
          (set! probe-phase 4)
          (match (aes.encrypt-256! (& live) (& source) (&mut destination))
            [(AesOk) unit]
            [_ (test.assert-true false "AES-256 residue probe")]))]
      [_ (test.assert-true false "AES-256 setup residue probe")])))

;: Exercise GCM setup, seal, successful open and authentication-failure cleanup.
(define (records) : unit
  (let
    [nonce : gcm.GcmNonce (gcm.GcmNonce (make-array u8 12))]
    [message : String "0123456789abcdefg"]
    [input : (& message bytes) (buf.str-as-bytes (& message))]
    (set! probe-phase 5)
    (match (gcm.new (secret.fixed-zero (secret.Secret16)))
      [(GcmKeyOk key)
        (with
          ([owner key gcm.close])
          (set! probe-phase 6)
          (match (gcm.seal (& owner) (& nonce) input input)
            [(GcmSealOk sealed)
              (set! probe-phase 7)
              (match (gcm.open
                (& owner)
                (& nonce)
                input
                (buf.as-bytes (& sealed.ciphertext))
                (& sealed.tag))
                [(GcmOpenOk plain)
                  (test.assert-i64-eq
                    (buf.len (& plain))
                    17
                    "open residue probe")]
                [_ (test.assert-true false "open residue probe")])
              (let
                [bad : gcm.GcmTag sealed.tag]
                (set!
                  (array-ref bad.octets 0)
                  (bit-xor (array-ref bad.octets 0) (cast 1 : u8)))
                (set! probe-phase 8)
                (match (gcm.open
                  (& owner)
                  (& nonce)
                  input
                  (buf.as-bytes (& sealed.ciphertext))
                  (& bad))
                  [(GcmOpenErr (GcmAuthentication)) unit]
                  [_ (test.assert-true false "bad-tag residue probe")]))]
            [_ (test.assert-true false "seal residue probe")]))]
      [_ (test.assert-true false "key residue probe")])))

(define (main) : i64
  (blocks)
  (records)
  42)