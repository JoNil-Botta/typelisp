(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (let
    [key : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    (aes.close-128-result (aes.new-128 key))
    (secret.fixed-length (& key))))