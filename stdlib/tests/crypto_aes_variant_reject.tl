(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)

(define (wrong
  [schedule : (& schedule aes.Aes256Schedule)]
  [source : (& source secret.SecretFixed)]
  [destination : (&mut destination secret.SecretFixed)]) : aes.AesStatus
  (aes.encrypt-128! schedule source destination))