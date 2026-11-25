;; Safe code cannot forge an HKDF PRK token from a raw pointer (#9783).
(import stdlib.crypto_hkdf_sha256 as hkdf)

(define (main) : i64
  (with
    ([prk
        (hkdf.HkdfSha256Prk (ptr-null : (MutPtr hkdf.HkdfSha256PrkStorage)))
        hkdf.close-prk])
    0))