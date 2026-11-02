(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_secret as secret)

;: Arbitrary fixed material cannot populate HKDF's protected PRK storage.
(define (forge [value : secret.SecretFixed]) : hkdf.HkdfSha256Prk
  (hkdf.HkdfSha256Prk (hkdf.HkdfSha256PrkStorage value)))