(import stdlib.crypto_secret as secret)

;: Even unsafe code cannot launder a consuming raw operation into a safe value.
(define (main) : i64
  (unsafe
    (let
      [call : (->
        secret.SecretTransferInput
        secret.SecretSize
        secret.SecretNominalResult)
        secret.transfer-fixed-input]
      (secret.close-nominal-result
        (call
          (secret.SecretTransferInput (secret.fixed-zero (secret.Secret32)))
          (secret.Secret32)))
      0)))