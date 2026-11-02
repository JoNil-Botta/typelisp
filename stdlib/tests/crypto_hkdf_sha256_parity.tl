(import stdlib.byte_buf as buf)
(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_hmac_sha256 as hmac)
(import stdlib.crypto_secret as secret)

;: An ordinary module can use both opaque owners without family authority.
(define (main) : i64
  (match (secret.bytes-new 0)
    [(SecretBytesErr _) 1]
    [(SecretBytesOk ikm)
      (with
        ([input ikm secret.close-bytes])
        (let
          [limits
            (hkdf.HkdfSha256Limits
              32
              0
              0
              8160
              32
              8383
              (hmac.HmacSha256Limits 32 33))]
          (match (hkdf.extract (& input) limits)
            [(HkdfSha256ExtractErr _) 2]
            [(HkdfSha256ExtractOk prk)
              (with
                ([key prk hkdf.close-prk])
                (match (hkdf.expand (& key) (buf.str-as-bytes "") 33 limits)
                  [(HkdfSha256ExpandErr _) 3]
                  [(HkdfSha256ExpandOk output)
                    (with
                      ([owned output hkdf.close-okm])
                      (let
                        [valid : bool
                          (and
                            (= (hkdf.okm-length (& owned)) 33)
                            (hkdf.prk-live? (& key)))]
                        (hkdf.close-prk (hkdf.HkdfSha256Prk key.storage))
                        (if (and valid (not (hkdf.prk-live? (& key))))
                          42
                          4)))]))])))]))