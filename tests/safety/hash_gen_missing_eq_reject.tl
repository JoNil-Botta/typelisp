;; `hash.gen` requires the owner equality hook, so a generated hash always
;; has an equality to keep its law with.
(import stdlib.hash)

(defstruct Point
  (x i64))

(hash.gen Point)

(define (main) : i64
  0)