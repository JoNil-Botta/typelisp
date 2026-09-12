(import stdlib.crypto_rsa_core as rsa)
(import stdlib.crypto_rsa_verify as verify)
(import stdlib.crypto_sha256 as sha)

(define (misuse
  [key : (& key rsa.RsaPublicKey)]
  [digest : (& digest sha.Sha256Digest)]
  [signature : (& signature bytes)]) : verify.RsaVerifyResult
  (verify.verify-pkcs1-sha256 key digest signature))