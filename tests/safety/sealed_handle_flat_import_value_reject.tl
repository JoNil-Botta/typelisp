;; A flat-imported sealed constructor used as a value is still a construction
;; (#9783).
(import stdlib.crypto_secret.*)

(define (main) : i64
  (let
    [f : (-> (MutPtr SecretStorage) i64 SecretHandle) SecretHandle]
    [h : SecretHandle (f (ptr-null : (MutPtr SecretStorage)) 1)]
    h.generation))