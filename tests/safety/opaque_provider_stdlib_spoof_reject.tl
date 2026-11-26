;; A file outside the stdlib that declares a stdlib module's dotted descendant
;; stays outside that module's (:opaque) family: the family also requires the
;; stdlib provider (#8733).
(module stdlib.crypto_secret.extra)

(import stdlib.crypto_secret as cs)

(define (storage-state [s : cs.SecretStorage]) : u64
  s.state)

(define (main) : i64
  0)