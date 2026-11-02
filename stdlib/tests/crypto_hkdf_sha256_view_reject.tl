(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_secret as secret)

;: Borrowed opaque PRK storage exposes no nominal field or readable view.
(define (view [storage : (& storage hkdf.HkdfSha256PrkStorage)]) : secret.SecretNominal
  storage.value)