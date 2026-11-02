(import stdlib.crypto_secret as secret)

;: An arbitrary fixed owner cannot populate the nominal backing state.
(define (main) : i64
  (let
    [owner : secret.SecretFixed (secret.fixed-zero (secret.Secret32))]
    [forged (secret.SecretNominalStorage (cast 0 : u64) 1 owner.handle)]
    (secret.close-fixed owner)
    0))