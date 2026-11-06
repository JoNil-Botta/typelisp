(import stdlib.crypto_p256 as p256)
(import stdlib.crypto_p256_ecdsa as ecdsa)
(import stdlib.crypto_sha256 as sha)

(define (misuse
  [key : p256.P256PublicPoint]
  [digest : (& digest sha.Sha256Digest)]
  [signature : (& signature bytes)]) : ecdsa.P256EcdsaVerifyResult
  (ecdsa.verify-sha256 key digest signature))