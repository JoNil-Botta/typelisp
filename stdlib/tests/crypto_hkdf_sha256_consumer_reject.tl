(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_secret as secret)

;: A different consumer's valid generic nominal owner is not an Extract PRK.
(define (forge [value : secret.SecretNominal]) : hkdf.HkdfSha256Prk
  (hkdf.HkdfSha256Prk (hkdf.HkdfSha256PrkStorage value)))