(import stdlib.crypto_hmac_sha256 as hmac)
(import stdlib.crypto_secret as secret)

(define (format-secret-result [result : (& result secret.SecretFixed)]) : String
  (hmac.to-hex result))