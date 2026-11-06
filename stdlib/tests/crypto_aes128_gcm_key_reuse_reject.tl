(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (let
    [key : secret.SecretFixed (secret.fixed-zero (secret.Secret16))]
    (gcm.close-key-result (gcm.new key))
    (secret.fixed-length (& key))))