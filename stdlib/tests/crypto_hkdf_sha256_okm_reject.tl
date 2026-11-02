(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_secret as secret)

;: Arbitrary variable secrets cannot populate protected OKM backing storage.
(define (forge [value : secret.SecretBytes]) : hkdf.HkdfSha256Okm
  (hkdf.HkdfSha256Okm (hkdf.HkdfSha256OkmStorage value)))