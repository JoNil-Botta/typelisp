(import stdlib.crypto_secret)

(define (main) : i64
  (let
    [owner : crypto_secret.SecretFixed
      (crypto_secret.fixed-zero (crypto_secret.Secret16))]
    [_header : crypto_secret.SecretStorage (ptr-read owner.storage)]
    (crypto_secret.close-fixed owner)
    42))