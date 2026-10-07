(import stdlib.crypto_secret)

(define (main) : i64
  (let
    [owner : crypto_secret.SecretFixed
      (crypto_secret.fixed-zero (crypto_secret.Secret16))]
    (crypto_secret.fixed-read-pointer (& owner) 0 16)
    (crypto_secret.close-fixed owner)
    42))