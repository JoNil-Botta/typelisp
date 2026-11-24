;; The raw storage cleanup hook is unsafe to call directly (#9783).
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (with
    ([owner (secret.fixed-zero (secret.Secret16)) secret.close-fixed])
    (secret.storage-close owner.handle)
    0))