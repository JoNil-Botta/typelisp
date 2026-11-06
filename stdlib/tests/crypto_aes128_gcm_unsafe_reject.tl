(import stdlib.crypto_aes128_gcm as gcm)
(import stdlib.crypto_secret as secret)

(define (bad
  [key : (& key gcm.GcmKey)]
  [nonce : (& nonce gcm.GcmNonce)]
  [counter : (&mut counter secret.SecretFixed)]
  [stream : (&mut stream secret.SecretFixed)]) : gcm.GcmStatus
  (gcm.prepare! key nonce counter stream))