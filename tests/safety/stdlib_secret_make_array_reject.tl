;; Safe code cannot zero-initialize a secret handle (#9783).
(import stdlib.crypto_secret as secret)

(define (main) : i64
  (let
    [handles : (Array secret.SecretHandle 1) (make-array secret.SecretHandle 1)]
    0))