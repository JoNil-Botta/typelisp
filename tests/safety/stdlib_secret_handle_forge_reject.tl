;; Safe code cannot forge a live secret owner from a raw pointer (#9783).
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (with
    ([owner
        (secret.SecretFixed
          (secret.SecretHandle (ptr-null : (MutPtr secret.SecretStorage)) 1))
        secret.close-fixed])
    0))