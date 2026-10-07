(import stdlib.crypto_secret)

(define (main) : i64
  (let
    [owner : crypto_secret.SecretFixed
      (crypto_secret.fixed-zero (crypto_secret.Secret16))]
    [copy : crypto_secret.SecretFixed (clone owner)]
    (crypto_secret.close-fixed copy)
    (crypto_secret.close-fixed owner)
    42))