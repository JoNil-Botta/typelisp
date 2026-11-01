(import stdlib.crypto_secret as secret)

;: Unsafe is not an escape hatch for a direct opaque representation read.
(define (peek [storage : (Ptr secret.SecretNominalStorage)]) : i64
  (unsafe
    (ptr-read storage))
  0)

(define (main) : i64
  0)