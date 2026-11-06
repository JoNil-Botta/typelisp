(import stdlib.crypto_aes_core as aes)
(import stdlib.crypto_secret as secret)

(define (bad
  [schedule : (& schedule aes.Aes128Schedule)]
  [source : (& source secret.SecretFixed)]
  [destination : (&mut destination secret.SecretFixed)]) : aes.AesStatus
  (aes.encrypt-checked! (& schedule.expanded) source destination 176 14 true))