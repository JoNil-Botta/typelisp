(import stdlib.clone)
(import stdlib.crypto_secret as secret)

(define (duplicate [owner : secret.SecretNominal]) : secret.SecretNominal
  (clone.deep owner))

(define (main) : i64
  0)