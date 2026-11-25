;; The PRK storage cleanup hook is unsafe to call directly (#9783).
(import stdlib.crypto_hkdf_sha256 as hkdf)

(define (main) : i64
  (hkdf.prk-storage-close (ptr-null : (MutPtr hkdf.HkdfSha256PrkStorage)))
  0)