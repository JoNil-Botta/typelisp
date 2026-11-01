(import stdlib.crypto_secret as secret)

(define (peek [owner : (& owner secret.SecretNominal)]) : secret.SecretReadResult
  (secret.nominal-read-pointer owner 0 32))

(define (main) : i64
  0)