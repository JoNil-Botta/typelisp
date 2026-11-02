(import stdlib.crypto_secret as secret)

(define (main) : i64
  (secret.close-nominal-result
    (secret.transfer-fixed
      (secret.fixed-zero (secret.Secret32))
      (secret.Secret32)))
  0)