(import stdlib.crypto_hkdf_sha256 as hkdf)

;: Direct checked crypto output access is never a safe readable view.
(define (view [output : (& output hkdf.HkdfSha256Okm)]) : unit
  (hkdf.okm-read-pointer output 0 0)
  unit)