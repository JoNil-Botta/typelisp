(import stdlib.crypto_secret as secret)

;: A fixed storage identity is not an identity of nominal backing state, even
;: in the unsafe code that may construct the sealed owner.
(define (main) : i64
  (let
    [owner : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [forged : secret.SecretNominal
      (unsafe
        (secret.SecretNominal
          (secret.SecretNominalHandle
            owner.handle.storage
            owner.handle.generation)))]
    (secret.close-fixed owner)
    (secret.close-nominal forged)
    0))