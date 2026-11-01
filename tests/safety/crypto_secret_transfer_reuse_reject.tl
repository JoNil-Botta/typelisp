(import stdlib.crypto_secret as secret)

(define (main) : i64
  (let
    [owner : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    (secret.close-nominal-result
      (unsafe
        (secret.transfer-fixed owner (secret.Secret32))))
    (secret.fixed-length (& owner))))