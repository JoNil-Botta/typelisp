(import stdlib.crypto_hkdf_sha256 as hkdf)
(import stdlib.crypto_secret as secret)

;: Borrowed opaque output storage exposes no underlying secret owner.
(define (view [storage : (& storage hkdf.HkdfSha256OkmStorage)]) : secret.SecretBytes
  storage.value)