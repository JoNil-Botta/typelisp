(import stdlib.crypto_hkdf_sha256 as hkdf)

;: The PRK token owns cleanup and cannot be cloned.
(define (duplicate [prk : hkdf.HkdfSha256Prk]) : hkdf.HkdfSha256Prk
  (let
    [copy : hkdf.HkdfSha256Prk (clone prk)]
    (hkdf.close-prk prk)
    copy))