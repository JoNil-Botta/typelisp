(import stdlib.crypto_secret as secret)

;: A fixed storage identity is not an identity of nominal backing state.
(define (main) : i64
  (let
    [owner : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [forged : secret.SecretNominal
      (secret.SecretNominal
        (secret.SecretNominalHandle
          owner.handle.storage
          owner.handle.generation))]
    (secret.close-fixed owner)
    (secret.close-nominal forged)
    0))