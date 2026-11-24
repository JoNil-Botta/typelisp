;; Safe code cannot retarget a secret owner's handle (#9783).
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (with
    ([owner (secret.fixed-zero (secret.Secret16)) secret.close-fixed])
    (set! owner.handle.generation 0)
    0))