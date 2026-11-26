;; Comptime reflection from a file outside the stdlib that declares a stdlib
;; module's dotted descendant cannot reach the representation of that module's
;; (:opaque) aggregates (#8733).
(module stdlib.crypto_secret.extra)

(import stdlib.crypto_secret as cs)

(define (main) : i64
  (comptime (size-of (type cs.SecretStorage))))