(import stdlib.crypto_hkdf_sha256 as hkdf)

;: No safe PRK-readable accessor is available.
(define (view [prk : (& prk hkdf.HkdfSha256Prk)]) : unit
  (hkdf.prk-read-pointer prk)
  unit)